"""Sample the trained model and decode to our engine's Song JSON.

p1->lead, p2->harmony, tr->bass, no->drums. The Rust chip-synth renders it,
so the 8-bit sound (the "soul") is preserved — the model only writes notes.
"""
import json, os, sys
import torch
from model import GPT, Config

ROOT = os.path.dirname(__file__)
CKPT = os.path.join(ROOT, "ckpt.pt")
device = "cuda" if torch.cuda.is_available() else "cpu"

INST_MAP = {"p1": "lead", "p2": "harmony", "tr": "bass", "no": "drums"}
INSTRUMENTS = [
    {"id": "lead", "waveform": "pulse", "duty": 0.5, "volume": 0.85, "pan": 0.28,
     "envelope": {"attack": 0.002, "decay": 0.06, "sustain": 0.7, "release": 0.06}},
    {"id": "harmony", "waveform": "pulse", "duty": 0.25, "volume": 0.5, "pan": -0.28,
     "envelope": {"attack": 0.002, "decay": 0.05, "sustain": 0.5, "release": 0.05}},
    {"id": "bass", "waveform": "triangle", "duty": 0.5, "volume": 0.95, "pan": 0.0,
     "envelope": {"attack": 0.002, "decay": 0.06, "sustain": 0.9, "release": 0.06}},
    {"id": "drums", "waveform": "noise", "duty": 0.5, "volume": 0.6, "pan": 0.0,
     "envelope": {"attack": 0.001, "decay": 0.03, "sustain": 0.0, "release": 0.03}},
]
VEL = {"lead": 0.95, "harmony": 0.55, "bass": 0.9, "drums": 0.85}


def load():
    ck = torch.load(CKPT, map_location=device, weights_only=False)
    cfg = Config(**ck["cfg"])
    model = GPT(cfg).to(device).eval()
    model.load_state_dict(ck["model"])
    return model, ck["meta"]


def decode(ids, meta):
    inv = {v: k for k, v in meta["vocab"].items()}
    spb = meta["steps_per_bar"]
    notes = {v: [] for v in INST_MAP.values()}
    bar, pos, inst, pitch = -1, 0, None, None
    for i in ids:
        t = inv.get(int(i), "PAD")
        if t == "BAR":
            bar += 1; pos = 0
        elif t.startswith("POS_"):
            pos = int(t[4:])
        elif t.startswith("INST_"):
            inst = INST_MAP.get(t[5:])
        elif t.startswith("PITCH_"):
            pitch = int(t[6:])
        elif t.startswith("DUR_") and inst and pitch is not None and bar >= 0:
            d = int(t[4:])
            start = bar * 4 + pos * (4.0 / spb)
            dur = d * (4.0 / spb)
            notes[inst].append({"pitch": pitch, "start": round(start, 3),
                                "duration": round(dur, 3), "velocity": VEL[inst]})
            pitch = None
        elif t == "EOS":
            break
    bars = bar + 1
    return notes, max(1, bars)


def _monophonic(notes):
    """Force a strictly monophonic line (real NES channels play ONE note at a
    time): drop simultaneous onsets and truncate any overlap. This is the main
    cure for the 'cacophony' — stacked notes on one voice."""
    notes.sort(key=lambda n: (n["start"], -n["pitch"]))
    out = []
    for n in notes:
        if out:
            prev = out[-1]
            if n["start"] <= prev["start"] + 1e-3:
                continue  # simultaneous note on a mono voice -> drop
            if prev["start"] + prev["duration"] > n["start"]:
                prev["duration"] = round(n["start"] - prev["start"], 3)
        if n["duration"] > 0.01:
            out.append(n)
    return [n for n in out if n["duration"] > 0.01]


def _relane(notes, center):
    """Octave-shift a whole voice to center its register, AND fold stray notes
    into a tight band so lead/harmony/bass never collide or jump octaves."""
    if not notes:
        return notes
    ps = sorted(n["pitch"] for n in notes)
    med = ps[len(ps) // 2]
    shift = 0
    while med + shift < center - 6:
        shift += 12
    while med + shift > center + 6:
        shift -= 12
    lo, hi = center - 10, center + 10
    for n in notes:
        p = n["pitch"] + shift
        while p < lo:
            p += 12
        while p > hi:
            p -= 12
        n["pitch"] = max(12, min(108, p))
    return notes


_MAJOR = {0, 2, 4, 5, 7, 9, 11}
_MINOR = {0, 2, 3, 5, 7, 8, 10}


def _detect_scale(notes_by_lane):
    """Find the best-fitting key (root + major/minor) from melodic pitches."""
    hist = [0] * 12
    for inst in ("lead", "harmony", "bass"):
        for n in notes_by_lane.get(inst, []):
            hist[n["pitch"] % 12] += 1
    best, best_pcs = -1, {0, 2, 4, 5, 7, 9, 11}
    for root in range(12):
        for base in (_MAJOR, _MINOR):
            pcs = {(root + i) % 12 for i in base}
            score = sum(hist[pc] for pc in pcs)
            if score > best:
                best, best_pcs = score, pcs
    return best_pcs


def _snap(notes, pcs):
    for n in notes:
        p = n["pitch"]
        if p % 12 in pcs:
            continue
        for d in (1, -1, 2, -2):
            if (p + d) % 12 in pcs:
                n["pitch"] = p + d
                break
    return notes


def _fallback_drums(bars):
    """A steady groove when the model didn't emit percussion."""
    out = []
    for b in range(bars):
        base = b * 4.0
        out.append({"pitch": 36, "start": base, "duration": 0.2, "velocity": 0.95})
        out.append({"pitch": 36, "start": base + 2, "duration": 0.2, "velocity": 0.85})
        out.append({"pitch": 38, "start": base + 1, "duration": 0.18, "velocity": 0.8})
        out.append({"pitch": 38, "start": base + 3, "duration": 0.18, "velocity": 0.8})
        for k in range(8):
            out.append({"pitch": 42, "start": base + k * 0.5, "duration": 0.1,
                        "velocity": 0.4 if k % 2 else 0.5})
    return out


_LANE = {"lead": 79, "harmony": 59, "bass": 40}  # drums: leave as-is


def to_song(notes, bars, bpm=120, title="Neural Chiptune"):
    pcs = _detect_scale(notes)
    tracks = []
    for inst in ["lead", "harmony", "bass", "drums"]:
        ns = _monophonic(notes[inst])
        if inst in _LANE:
            ns = _snap(ns, pcs)
            ns = _relane(ns, _LANE[inst])
        if inst == "drums" and len(ns) < bars:
            ns = _fallback_drums(bars)  # guarantee a rhythmic backbone
        tracks.append({"instrument": inst, "notes": ns})
    return {
        "title": title, "bpm": bpm, "master_volume": 0.8,
        "instruments": INSTRUMENTS,
        "patterns": [{"id": "song", "length_beats": bars * 4, "tracks": tracks}],
        "arrangement": ["song"],
    }


def main():
    temp = float(sys.argv[1]) if len(sys.argv) > 1 else 0.95
    max_new = int(sys.argv[2]) if len(sys.argv) > 2 else 1200
    model, meta = load()
    bos = meta["vocab"]["BOS"]
    idx = torch.tensor([[bos]], dtype=torch.long, device=device)
    out = model.generate(idx, max_new, temperature=temp, top_k=40)[0].tolist()
    notes, bars = decode(out, meta)
    song = to_song(notes, bars)
    counts = {k: len(v) for k, v in notes.items()}
    print("bars:", bars, "notes:", counts, file=sys.stderr)
    json.dump(song, open(os.path.join(ROOT, "generated_song.json"), "w"))
    print("wrote generated_song.json", file=sys.stderr)


if __name__ == "__main__":
    main()
