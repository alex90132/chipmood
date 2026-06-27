"""NES-MDB MIDI -> token stream for a small GPT.

Representation (REMI-like) over a 16th-note grid, 4 NES voices:
  BOS, [BAR, POS_p, INST_x, PITCH_n, DUR_d, ...], EOS
Voices: p1,p2,tr,no  ->  our lead,harmony,bass,drums.
Timing uses beats = ticks / ticks_per_beat (NES-MDB's beat unit), quantized to
16th notes. Long songs are chunked into windows of BARS_PER_CHUNK bars.
"""
import glob, json, os, struct
import mido
import numpy as np
from tqdm import tqdm

ROOT = os.path.dirname(__file__)
MIDI = os.path.join(ROOT, "nesmdb_midi")
OUT = os.path.join(ROOT, "data")
os.makedirs(OUT, exist_ok=True)

INSTS = ["p1", "p2", "tr", "no"]
STEPS_PER_BAR = 16          # 16th notes, 4/4
MAX_DUR = 16
BARS_PER_CHUNK = 24
PITCH_MIN, PITCH_MAX = 24, 108

# ---- vocabulary -----------------------------------------------------------
def build_vocab():
    toks = ["PAD", "BOS", "EOS", "BAR"]
    toks += [f"POS_{i}" for i in range(STEPS_PER_BAR)]
    toks += [f"INST_{x}" for x in INSTS]
    toks += [f"PITCH_{p}" for p in range(PITCH_MIN, PITCH_MAX + 1)]
    toks += [f"DUR_{d}" for d in range(1, MAX_DUR + 1)]
    return {t: i for i, t in enumerate(toks)}

VOCAB = build_vocab()


def notes_from_midi(path):
    """Return list of (start16, dur16, inst_idx, pitch) for a file."""
    try:
        m = mido.MidiFile(path)
    except Exception:
        return []
    tpb = m.ticks_per_beat or 480
    out = []
    for tr in m.tracks:
        name = None
        for msg in tr:
            if msg.type == "track_name":
                name = msg.name.strip().lower()
                break
        if name not in INSTS:
            continue
        inst = INSTS.index(name)
        t = 0
        active = {}  # pitch -> start_tick
        for msg in tr:
            t += msg.time
            if msg.type == "note_on" and msg.velocity > 0:
                active[msg.note] = t
            elif msg.type == "note_off" or (msg.type == "note_on" and msg.velocity == 0):
                s = active.pop(msg.note, None)
                if s is None:
                    continue
                start16 = int(round((s / tpb) * 4))
                dur16 = max(1, min(MAX_DUR, int(round(((t - s) / tpb) * 4))))
                p = msg.note
                if inst == 3:  # noise: collapse to a few "drum" pitches
                    p = 36 + (p % 4) * 2
                if p < PITCH_MIN or p > PITCH_MAX:
                    p = max(PITCH_MIN, min(PITCH_MAX, p))
                out.append((start16, dur16, inst, p))
    out.sort(key=lambda e: (e[0], e[2], e[3]))
    return out


def encode_song(notes):
    """Yield token-id sequences (chunked) for one song."""
    if not notes:
        return
    by_bar = {}
    for (s16, d16, inst, p) in notes:
        bar = s16 // STEPS_PER_BAR
        by_bar.setdefault(bar, []).append((s16 % STEPS_PER_BAR, inst, d16, p))
    max_bar = max(by_bar)
    for chunk_start in range(0, max_bar + 1, BARS_PER_CHUNK):
        seq = [VOCAB["BOS"]]
        any_note = False
        for bar in range(chunk_start, min(chunk_start + BARS_PER_CHUNK, max_bar + 1)):
            seq.append(VOCAB["BAR"])
            evs = sorted(by_bar.get(bar, []))
            last_pos = -1
            for (pos, inst, d16, p) in evs:
                if pos != last_pos:
                    seq.append(VOCAB[f"POS_{pos}"])
                    last_pos = pos
                seq.append(VOCAB[f"INST_{INSTS[inst]}"])
                seq.append(VOCAB[f"PITCH_{p}"])
                seq.append(VOCAB[f"DUR_{d16}"])
                any_note = True
        seq.append(VOCAB["EOS"])
        if any_note and len(seq) > 8:
            yield seq


def process(split):
    files = sorted(glob.glob(os.path.join(MIDI, split, "*.mid")))
    ids = []
    songs = 0
    for f in tqdm(files, desc=split):
        notes = notes_from_midi(f)
        for seq in encode_song(notes):
            ids.extend(seq)
            songs += 1
    arr = np.array(ids, dtype=np.uint16)
    arr.tofile(os.path.join(OUT, f"{split}.bin"))
    return len(files), songs, len(arr)


if __name__ == "__main__":
    json.dump(
        {"vocab": VOCAB, "steps_per_bar": STEPS_PER_BAR, "max_dur": MAX_DUR,
         "insts": INSTS, "pitch_min": PITCH_MIN, "pitch_max": PITCH_MAX},
        open(os.path.join(OUT, "meta.json"), "w"),
    )
    print("vocab size:", len(VOCAB))
    for sp in ["train", "valid", "test"]:
        nf, ns, nt = process(sp)
        print(f"{sp}: files={nf} chunks={ns} tokens={nt}")
