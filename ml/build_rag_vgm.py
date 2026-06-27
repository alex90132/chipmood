"""Build a SECOND RAG exemplar set from the foldl/midi dataset (~20k multi-track
General-MIDI songs, genre-labelled — rich 8-18 voice arrangements with real
tempos). We reduce each song to our four-voice schema (lead / harmony / bass /
drums) so it slots beside the NES exemplars, but it brings much wider melodic,
harmonic and rhythmic vocabulary than the 4-channel NES set.

Pipeline per song: recover MIDI bytes -> pretty_midi -> pick lead/harmony/bass
by register & activity, merge drums (GM -> kick/snare/hat) -> quantize to 16ths
on the beat grid -> transpose tonic to C -> take the catchiest 8-bar hook ->
normalize dynamics -> tag mood (key + tempo + density).

Output: assets/rag/vgm_exemplars.json  (same compact format as the NES set)
"""
import ast, io, json, os, random
from collections import Counter

import numpy as np
import pretty_midi
import pyarrow.parquet as pq
from huggingface_hub import hf_hub_download

import build_rag as B  # reuse detect_key, degree_of, best_window, constants

ROOT = os.path.dirname(__file__)
OUT = os.path.join(ROOT, "..", "assets", "rag")
os.makedirs(OUT, exist_ok=True)

REPO = "foldl/midi"
PARQUETS = [
    "data/train-00000-of-00005-668958f82ec6a61b.parquet",
    "data/train-00001-of-00005-3156cf7ad1129c97.parquet",
    "data/train-00002-of-00005-7f43f596745a97cd.parquet",
    "data/train-00003-of-00005-49115c2d74b11d9a.parquet",
    "data/train-00004-of-00005-9e0b4e269279affd.parquet",
]
SPB = B.SPB
WIN = B.WIN
PER_MOOD = 200
MAX_SCAN = 6000   # how many songs to look at across the parquets


def gm_drum(pitch):
    """General-MIDI percussion note -> our 4 drum tones."""
    if pitch in (35, 36):
        return 36          # kick
    if pitch in (38, 40, 37, 39):
        return 38          # snare / clap
    if pitch in (42, 44, 46, 51, 59, 49, 57):
        return 42          # hats / cymbals
    return 40              # toms / perc


def to_step(time, beats):
    i = int(np.searchsorted(beats, time)) - 1
    i = max(0, min(i, len(beats) - 2))
    span = beats[i + 1] - beats[i]
    frac = (time - beats[i]) / span if span > 1e-6 else 0.0
    return int(round((i + frac) * 4))


def extract_lanes(pm):
    """Return {0:lead,1:harmony,2:bass,3:drums} as (s16,d16,pitch,vel) tuples."""
    beats = pm.get_beats()
    if len(beats) < 4:
        return None
    melodic = [ins for ins in pm.instruments if not ins.is_drum and len(ins.notes) >= 8]
    drumset = [ins for ins in pm.instruments if ins.is_drum and ins.notes]
    if len(melodic) < 2:
        return None
    # mean pitch + activity per melodic instrument
    stats = []
    for ins in melodic:
        mp = sum(n.pitch for n in ins.notes) / len(ins.notes)
        stats.append((mp, len(ins.notes), ins))
    stats.sort(key=lambda s: s[0])             # low -> high register
    bass_ins = stats[0][2]
    # lead = busiest among the upper half by register
    upper = stats[len(stats) // 2:]
    lead_ins = max(upper, key=lambda s: s[1])[2]
    # harmony = busiest remaining (not lead, not bass)
    rest = [s for s in stats if s[2] not in (lead_ins, bass_ins)]
    harm_ins = max(rest, key=lambda s: s[1])[2] if rest else None
    # counter = next busiest remaining (a real secondary melodic line)
    rest2 = [s for s in rest if s[2] is not harm_ins]
    counter_ins = max(rest2, key=lambda s: s[1])[2] if rest2 else None

    def conv(ins, collapse_drums=False):
        out = []
        for n in ins.notes:
            s16 = to_step(n.start, beats)
            e16 = to_step(n.end, beats)
            d16 = max(1, min(B.P.MAX_DUR, e16 - s16))
            p = gm_drum(n.pitch) if collapse_drums else n.pitch
            p = max(B.P.PITCH_MIN, min(B.P.PITCH_MAX, p))
            out.append((s16, d16, p, n.velocity))
        return out

    lanes = {
        0: conv(lead_ins),
        1: conv(harm_ins) if harm_ins else [],
        2: conv(bass_ins),
        3: [],
        4: conv(counter_ins) if counter_ins else [],
    }
    for d in drumset:
        lanes[3].extend(conv(d, collapse_drums=True))
    lanes[3].sort()
    return lanes, lead_ins.program


def gm_timbre(program):
    """General-MIDI program -> a timbre keyword our arranger maps to a waveform."""
    if 80 <= program <= 87:
        return "square"        # synth lead
    if 88 <= program <= 95:
        return "string"        # synth pad
    if 56 <= program <= 63:
        return "brass"
    if 40 <= program <= 55:
        return "string"
    if 16 <= program <= 23:
        return "organ"
    if 64 <= program <= 79:
        return "reed"          # reed / pipe / flute
    if 24 <= program <= 31:
        return "bright"        # guitar
    if 0 <= program <= 7:
        return "mellow"        # piano
    return "bright"


def build_one(name, genre, pm):
    try:
        lanes, lead_program = extract_lanes(pm)
    except Exception:
        return None
    if not lanes or len(lanes[0]) < 8:
        return None

    hist = [0] * 12
    for ln in (0, 1, 2):
        for (_, d16, p, _) in lanes[ln]:
            hist[p % 12] += d16
    root, mode = B.detect_key(hist)
    scale = B.MAJOR if mode == "major" else B.MINOR
    shift = -root if root <= 6 else 12 - root

    total_bars = max(n[0] // SPB for n in lanes[0]) + 1
    start = B.best_window(lanes[0], total_bars)

    maxv = max((v for ln in lanes.values() for (_, _, _, v) in ln), default=0)
    def vscale(v):
        return 0.85 if maxv <= 0 else round(0.5 + 0.45 * (v / maxv), 2)

    lead = B._phrase(lanes[0], shift, start, 40, vscale)
    if len(lead) < 6:
        return None
    harmony = B._phrase(lanes[1], shift, start, 32, vscale)
    counter = B._phrase(lanes[4], shift, start, 28, vscale)
    bass = B._phrase(lanes[2], shift, start, 28, vscale)
    drums = B._drum_phrase(lanes[3], start, 64, vscale)

    chords = []
    for b in range(WIN):
        lo, hi = (start + b) * SPB, (start + b + 1) * SPB
        pcs = [p % 12 for ln in (2, 1, 0)
               for (s16, d16, p, v) in lanes[ln] if lo <= s16 < hi]
        if not pcs:
            chords.append(chords[-1] if chords else 0)
        else:
            common = Counter(pcs).most_common(1)[0][0]
            chords.append(B.degree_of(common, root, scale))

    tempo = round(pm.get_tempo_changes()[1][0]) if len(pm.get_tempo_changes()[1]) else 120
    bpm = int(max(70, min(190, tempo)))
    npb = len(lead) / WIN
    arousal = 1 if (npb >= 4 or bpm >= 135) else 0
    valence = 1 if mode == "major" else 0
    quad = {(1, 1): "happy", (0, 1): "tense", (0, 0): "sad", (1, 0): "calm"}[(valence, arousal)]

    return {
        "title": name[:48], "source": "vgm", "genre": genre[:3],
        "mood": quad, "valence": valence, "arousal": arousal,
        "scale": mode, "bpm": bpm, "bars": WIN, "timbre": gm_timbre(lead_program),
        "chords": chords, "lead": lead, "harmony": harmony, "counter": counter,
        "bass": bass, "drums": drums,
    }


def main():
    out, scanned = [], 0
    for pqfile in PARQUETS:
        if scanned >= MAX_SCAN:
            break
        path = hf_hub_download(REPO, pqfile, repo_type="dataset")
        t = pq.read_table(path)
        n = t.num_rows
        names, genres, midis = t.column("name"), t.column("genre"), t.column("midi")
        for i in range(n):
            if scanned >= MAX_SCAN:
                break
            scanned += 1
            try:
                name = names[i].as_py() or "vgm"
                genre = ast.literal_eval(genres[i].as_py())
                b = ast.literal_eval(midis[i].as_py())
                pm = pretty_midi.PrettyMIDI(io.BytesIO(b))
            except Exception:
                continue
            e = build_one(name, genre, pm)
            if e:
                out.append(e)
        print(f"  {pqfile.split('/')[-1]}: scanned={scanned} usable={len(out)}")

    random.seed(0)
    random.shuffle(out)
    by_mood = {}
    for e in out:
        by_mood.setdefault(e["mood"], []).append(e)
    capped = []
    for m, xs in by_mood.items():
        capped.extend(xs[:PER_MOOD])
    random.shuffle(capped)
    json.dump(capped, open(os.path.join(OUT, "vgm_exemplars.json"), "w"))
    print("total usable:", len(out), "-> capped:", len(capped))
    print("by mood:", {m: len(xs[:PER_MOOD]) for m, xs in by_mood.items()})


if __name__ == "__main__":
    import warnings
    warnings.filterwarnings("ignore")
    main()
