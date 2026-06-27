"""Convert decoded Orpheus notes into the ChipMood Song JSON the Rust chip-synth
plays. Orpheus emits GM-style multi-instrument notes in milliseconds; we reduce
them to our four chip voices (lead / harmony / bass / drums) in beat units and
apply the same musical clean-up the offline path uses (monophonic voices,
key-snap, register folding) so the result is coherent on the 8-bit engine.
"""
import orpheus_common as OC

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
MOOD_BPM = {"happy": 132, "calm": 96, "sad": 84, "tense": 142}
_MAJOR = {0, 2, 4, 5, 7, 9, 11}
_MINOR = {0, 2, 3, 5, 7, 8, 10}
_LANE = {"lead": 79, "harmony": 59, "bass": 40}


def _role(pitch, patch, channel):
    if patch == 128 or channel == 9:
        return "drums"
    if patch in (32, 33, 34, 35, 36, 37, 38, 39) or pitch < 52:
        return "bass"
    if pitch >= 68:
        return "lead"
    return "harmony"


def _monophonic(notes):
    notes.sort(key=lambda n: (n["start"], -n["pitch"]))
    out = []
    for n in notes:
        if out:
            prev = out[-1]
            if n["start"] <= prev["start"] + 1e-3:
                continue
            if prev["start"] + prev["duration"] > n["start"]:
                prev["duration"] = round(n["start"] - prev["start"], 3)
        if n["duration"] > 0.01:
            out.append(n)
    return [n for n in out if n["duration"] > 0.01]


def _detect_scale(by):
    hist = [0] * 12
    for inst in ("lead", "harmony", "bass"):
        for n in by.get(inst, []):
            hist[n["pitch"] % 12] += 1
    best, best_pcs = -1, _MAJOR
    for root in range(12):
        for base in (_MAJOR, _MINOR):
            pcs = {(root + i) % 12 for i in base}
            s = sum(hist[pc] for pc in pcs)
            if s > best:
                best, best_pcs = s, pcs
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


def _relane(notes, center):
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


def _fallback_drums(bars):
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


def tokens_to_song(tokens, mood="happy", bpm=None, title="Orpheus Chiptune"):
    bpm = bpm or MOOD_BPM.get(mood, 120)
    spb_ms = 60000.0 / bpm  # ms per beat
    raw = OC.tokens_to_notes(tokens)  # ['note', t_ms, dur_ms, ch, pitch, vel, patch]
    lanes = {"lead": [], "harmony": [], "bass": [], "drums": []}
    for _, t_ms, dur_ms, ch, pitch, vel, patch in raw:
        lane = _role(pitch, patch, ch)
        lanes[lane].append({
            "pitch": int(pitch),
            "start": round(t_ms / spb_ms, 3),
            "duration": round(max(dur_ms, 60) / spb_ms, 3),
            "velocity": round(max(0.2, min(1.0, vel / 127.0)), 2),
        })

    end_beat = 4.0
    for ns in lanes.values():
        for n in ns:
            end_beat = max(end_beat, n["start"] + n["duration"])
    bars = max(1, int(round(end_beat / 4.0)))

    pcs = _detect_scale(lanes)
    tracks = []
    for inst in ["lead", "harmony", "bass", "drums"]:
        ns = _monophonic(lanes[inst])
        if inst in _LANE:
            ns = _snap(ns, pcs)
            ns = _relane(ns, _LANE[inst])
        if inst == "drums" and len(ns) < bars:
            ns = _fallback_drums(bars)
        tracks.append({"instrument": inst, "notes": ns})

    return {
        "title": title, "bpm": bpm, "master_volume": 0.8,
        "instruments": INSTRUMENTS,
        "patterns": [{"id": "song", "length_beats": bars * 4, "tracks": tracks}],
        "arrangement": ["song"],
    }
