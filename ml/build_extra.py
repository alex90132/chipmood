"""Mine two extra datasets into RAG exemplars so the library gets SMARTER:

  * POP909  — 909 pop songs as 3 named tracks (MELODY / BRIDGE / PIANO). Gives
    real pop melodic vocabulary, a genuine secondary line (BRIDGE -> our
    counter) and real chord motion (fixes static harmony). source='pop'.
  * EMOPIA  — 1078 solo-piano clips labelled by the 4 valence/arousal quadrants
    (Q1 happy, Q2 tense, Q3 sad, Q4 calm) — PRECISE mood tags that match ours,
    so mood retrieval stops guessing. source='emo'.

Both are reduced to our voice schema, normalized to key C, windowed to the
catchiest 8 bars and written in the same compact exemplar format the app loads.

Outputs: assets/rag/pop_exemplars.json, assets/rag/emo_exemplars.json
"""
import glob, json, os, warnings
from collections import Counter, defaultdict

import numpy as np
import pretty_midi

import build_rag as B
import build_ut as U
import prepare_data as P

warnings.filterwarnings("ignore")
ROOT = os.path.dirname(__file__)
OUT = os.path.join(ROOT, "..", "assets", "rag")
SPB = B.SPB
PER_MOOD = 200
EMO_QUAD = {"Q1": "happy", "Q2": "tense", "Q3": "sad", "Q4": "calm"}


def to_step(time, beats):
    i = int(np.searchsorted(beats, time)) - 1
    i = max(0, min(i, len(beats) - 2))
    span = beats[i + 1] - beats[i]
    frac = (time - beats[i]) / span if span > 1e-6 else 0.0
    return int(round((i + frac) * 4))


def conv(notes, beats):
    """pretty_midi notes -> sorted (s16, d16, pitch, vel) in our grid."""
    out = []
    for n in notes:
        s = to_step(n.start, beats)
        e = to_step(n.end, beats)
        d = max(1, min(P.MAX_DUR, e - s))
        p = max(P.PITCH_MIN, min(P.PITCH_MAX, n.pitch))
        out.append((s, d, p, n.velocity))
    out.sort()
    return out


def mono_top(notes, pick_low=False):
    """Reduce polyphony to one note per onset step (highest, or lowest)."""
    by_step = defaultdict(list)
    for (s, d, p, v) in notes:
        by_step[s].append((s, d, p, v))
    out = []
    for s, group in by_step.items():
        out.append(min(group, key=lambda x: x[2]) if pick_low
                   else max(group, key=lambda x: x[2]))
    out.sort()
    return out


def finalize(name, source, mood, lanes, bpm):
    """lanes: {0:lead,1:harmony,2:bass,3:drums,4:counter} of (s16,d16,p,v)."""
    if len(lanes[0]) < 8:
        return None
    hist = [0] * 12
    for ln in (0, 1, 2):
        for (_, d16, p, _v) in lanes[ln]:
            hist[p % 12] += d16
    if sum(hist) == 0:
        return None
    root, mode = B.detect_key(hist)
    scale = B.MAJOR if mode == "major" else B.MINOR
    shift = -root if root <= 6 else 12 - root

    total_bars = max(n[0] // SPB for n in lanes[0]) + 1
    start = U.best_mel_window(lanes[0], total_bars)
    allv = [v for ln in lanes.values() for (_, _, _, v) in ln]
    maxv = max(allv) if allv else 0

    def vscale(v):
        return 0.85 if maxv <= 0 else round(0.5 + 0.45 * (v / maxv), 2)

    lead = B._phrase(lanes[0], shift, start, 40, vscale)
    if len(lead) < 6 or not U.is_real_melody(lead):
        return None
    harmony = B._phrase(lanes[1], shift, start, 32, vscale)
    counter = B._phrase(lanes[4], shift, start, 28, vscale)
    bass = B._phrase(lanes[2], shift, start, 28, vscale)
    drums = B._drum_phrase(lanes[3], start, 64, vscale)

    chords = []
    for b in range(B.WIN):
        lo, hi = (start + b) * SPB, (start + b + 1) * SPB
        pcs = [p % 12 for ln in (2, 1, 0)
               for (s16, d16, p, v) in lanes[ln] if lo <= s16 < hi]
        chords.append(B.degree_of(Counter(pcs).most_common(1)[0][0], root, scale)
                      if pcs else (chords[-1] if chords else 0))

    npb = len(lead) / B.WIN
    if mood is None:                       # derive when unlabeled (POP909)
        arousal = 1 if (npb >= 4 or bpm >= 135) else 0
        valence = 1 if mode == "major" else 0
        mood = {(1, 1): "happy", (0, 1): "tense", (0, 0): "sad",
                (1, 0): "calm"}[(valence, arousal)]
    valence = 1 if mood in ("happy", "calm") else 0
    arousal = 1 if mood in ("happy", "tense") else 0
    return {
        "title": name[:48], "source": source, "mood": mood,
        "valence": valence, "arousal": arousal, "scale": mode,
        "bpm": int(max(70, min(190, bpm))), "bars": B.WIN,
        "chords": chords, "lead": lead, "harmony": harmony,
        "counter": counter, "bass": bass, "drums": drums,
    }


def safe_bpm(pm):
    try:
        t = pm.estimate_tempo()
    except Exception:
        t = 120.0
    if not (60 <= t <= 200):
        t = 120.0
    return round(t)


def build_pop909(limit=909):
    from huggingface_hub import snapshot_download
    repo = snapshot_download("c0smic1atte/909_aligned", repo_type="dataset",
                             allow_patterns="POP909-aligned/*.mid")
    files = sorted(glob.glob(os.path.join(repo, "POP909-aligned", "*.mid")))[:limit]
    out = []
    for f in files:
        try:
            pm = pretty_midi.PrettyMIDI(f)
            beats = pm.get_beats()
            if len(beats) < 8:
                continue
            tracks = {t.name.upper(): t for t in pm.instruments if not t.is_drum}
            mel = tracks.get("MELODY")
            if mel is None or len(mel.notes) < 8:
                continue
            bridge = tracks.get("BRIDGE")
            piano = tracks.get("PIANO")
            piano_n = conv(piano.notes, beats) if piano else []
            lanes = {
                0: conv(mel.notes, beats),
                1: mono_top(piano_n),                       # comp top -> harmony
                2: mono_top(piano_n, pick_low=True),        # comp bottom -> bass
                3: [],
                4: conv(bridge.notes, beats) if bridge else [],
            }
            e = finalize(os.path.basename(f).replace(".mid", "pop"),
                         "pop", None, lanes, safe_bpm(pm))
            if e:
                out.append(e)
        except Exception:
            continue
    return out


def build_emopia():
    out = []
    files = sorted(glob.glob(
        os.path.join(ROOT, "data", "emopia", "EMOPIA_1.0", "midis", "*.mid")))
    for f in files:
        q = os.path.basename(f)[:2]
        mood = EMO_QUAD.get(q)
        if mood is None:
            continue
        try:
            pm = pretty_midi.PrettyMIDI(f)
            beats = pm.get_beats()
            if len(beats) < 8 or not pm.instruments:
                continue
            piano = conv(pm.instruments[0].notes, beats)
            if len(piano) < 12:
                continue
            # split the solo piano by register: top = melody, bottom = bass
            lanes = {
                0: mono_top(piano),                 # melody (top voice)
                1: [],
                2: mono_top(piano, pick_low=True),  # bass (bottom voice)
                3: [],
                4: [],
            }
            # harmony = a middle voice: median pitch per onset
            by_step = defaultdict(list)
            for n in piano:
                by_step[n[0]].append(n)
            mid = []
            for s, g in by_step.items():
                g.sort(key=lambda x: x[2])
                mid.append(g[len(g) // 2])
            mid.sort()
            lanes[1] = mid
            e = finalize(os.path.basename(f).replace(".mid", ""),
                         "emo", mood, lanes, safe_bpm(pm))
            if e:
                out.append(e)
        except Exception:
            continue
    return out


def cap_by_mood(items):
    by = {}
    for e in items:
        by.setdefault(e["mood"], []).append(e)
    out = []
    for m, xs in by.items():
        out.extend(xs[:PER_MOOD])
    return out, {m: len(xs[:PER_MOOD]) for m, xs in by.items()}


def piano_lanes(piano, mood):
    """Split a solo-piano note list into lead(top)/harmony(mid)/bass(bottom)."""
    if len(piano) < 12:
        return None
    by_step = defaultdict(list)
    for n in piano:
        by_step[n[0]].append(n)
    mid = []
    for s, g in by_step.items():
        g.sort(key=lambda x: x[2])
        mid.append(g[len(g) // 2])
    mid.sort()
    return {
        0: mono_top(piano),
        1: mid,
        2: mono_top(piano, pick_low=True),
        3: [],
        4: [],
    }


def build_vgmidi():
    """VGMIDI — ~200 solo-piano arrangements of video-game soundtracks. Split
    the piano into our voices; mood derived from the music. source='vg'."""
    from huggingface_hub import snapshot_download
    try:
        repo = snapshot_download("30yu/vgmidi", repo_type="dataset",
                                 allow_patterns=["*.mid", "**/*.mid"])
    except Exception as e:
        print("VGMIDI download skipped:", e)
        return []
    files = sorted(glob.glob(os.path.join(repo, "**", "*.mid"), recursive=True))
    out = []
    for f in files:
        try:
            pm = pretty_midi.PrettyMIDI(f)
            beats = pm.get_beats()
            if len(beats) < 8 or not pm.instruments:
                continue
            notes = []
            for ins in pm.instruments:
                if not ins.is_drum:
                    notes += conv(ins.notes, beats)
            notes.sort()
            lanes = piano_lanes(notes, None)
            if lanes is None:
                continue
            e = finalize(os.path.basename(f).replace(".mid", ""), "vg", None,
                         lanes, safe_bpm(pm))
            if e:
                out.append(e)
        except Exception:
            continue
    return out


def build_ym2413(local_dir=None):
    """YM2413-MDB — 80s FM video-game music with 4-quadrant emotion labels.
    The dataset is a ~6.4 GB Zenodo archive (audio+MIDI), so it is NOT fetched
    automatically. Download it (https://zenodo.org/record/7520537), unzip, and
    point `local_dir` (or env YM2413_DIR) at the folder. We then mine the MIDIs,
    reading the emotion label (Q1..Q4 / valence-arousal) from the annotation CSV.
    """
    import csv
    import build_rag_vgm as V
    base = local_dir or os.environ.get("YM2413_DIR")
    if not base or not os.path.isdir(base):
        print("YM2413-MDB skipped: set YM2413_DIR to the downloaded dataset "
              "folder to mine it (6.4 GB Zenodo archive, not auto-fetched).")
        return []
    # Map any emotion/quadrant column to our mood; tolerant to schema variants.
    def mood_of(row):
        text = " ".join(str(v).lower() for v in row.values())
        if "q1" in text or ("high" in text and "positive" in text):
            return "happy"
        if "q2" in text:
            return "tense"
        if "q3" in text:
            return "sad"
        if "q4" in text:
            return "calm"
        return None
    labels = {}
    for cf in glob.glob(os.path.join(base, "**", "*.csv"), recursive=True):
        try:
            for row in csv.DictReader(open(cf)):
                fn = next((row[k] for k in row if "file" in k.lower()
                           or "name" in k.lower() or "id" in k.lower()), None)
                m = mood_of(row)
                if fn and m:
                    labels[os.path.splitext(os.path.basename(str(fn)))[0]] = m
        except Exception:
            continue
    # YM2413-MDB ships the same 669 songs in three MIDI variants; prefer the
    # cleanest melodic one and mine each song just once.
    mid_root = os.path.join(base, "midi", "adjust_tempo_remove_delayed_inst")
    if not os.path.isdir(mid_root):
        mid_root = base
    out = []
    seen = set()
    for f in sorted(glob.glob(os.path.join(mid_root, "**", "*.mid"), recursive=True)):
        key = os.path.splitext(os.path.basename(f))[0]
        if key in seen:
            continue
        seen.add(key)
        try:
            pm = pretty_midi.PrettyMIDI(f)
            e = V.build_one(key, ["ym"], pm)
            if e:
                e["source"] = "ym"
                if key in labels:
                    e["mood"] = labels[key]
                out.append(e)
        except Exception:
            continue
    return out


def main():
    pop = build_pop909()
    pop, pc = cap_by_mood(pop)
    json.dump(pop, open(os.path.join(OUT, "pop_exemplars.json"), "w"))
    print("POP909 exemplars:", len(pop), pc)

    emo = build_emopia()
    emo, ec = cap_by_mood(emo)
    json.dump(emo, open(os.path.join(OUT, "emo_exemplars.json"), "w"))
    print("EMOPIA exemplars:", len(emo), ec)

    vg = build_vgmidi()
    vg, vc = cap_by_mood(vg)
    json.dump(vg, open(os.path.join(OUT, "vg_exemplars.json"), "w"))
    print("VGMIDI exemplars:", len(vg), vc)

    ym = build_ym2413()
    if ym:
        ym, yc = cap_by_mood(ym)
        json.dump(ym, open(os.path.join(OUT, "ym_exemplars.json"), "w"))
        print("YM2413 exemplars:", len(ym), yc)


if __name__ == "__main__":
    main()
