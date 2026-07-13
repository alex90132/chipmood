"""A/B pair from one real NES-MDB MIDI:

  A  = authentic NES-chip softsynth of the MIDI (what the file 'is')
  B  = the SAME notes through ChipMood's Rust engine

Pushes both MP3s to the phone Music folder for side-by-side listening.
"""
from __future__ import annotations

import json, math, os, struct, subprocess, sys, wave

import numpy as np

ROOT = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, ROOT)
import prepare_data as P  # noqa: E402

MIDI = os.path.join(
    ROOT, "nesmdb_midi", "train",
    "046_CastlevaniaIII_Dracula_sCurse_02_03Beginning.mid",
)
OUT = os.path.join(ROOT, "..", "reference", "ab")
os.makedirs(OUT, exist_ok=True)
SECONDS = 55.0
SR = 44100
BPM = 125.0  # NES-MDB tracks are tempo-normalized around this in our pipeline

# Same defaults as ml/generate.py (avoid importing torch).
VEL = {"lead": 0.95, "harmony": 0.55, "bass": 0.9, "drums": 0.85}
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


def _monophonic(notes):
    notes = sorted(notes, key=lambda n: (n["start"], -n["pitch"]))
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


def to_song(notes, bars, bpm=125.0, title="ChipMood"):
    tracks = []
    for inst in ["lead", "harmony", "bass", "drums"]:
        ns = _monophonic(list(notes[inst]))
        tracks.append({"instrument": inst, "notes": ns})
    return {
        "title": title, "bpm": bpm, "master_volume": 0.85, "delay_wet": 0.0,
        "instruments": INSTRUMENTS,
        "patterns": [{"id": "song", "length_beats": bars * 4, "tracks": tracks}],
        "arrangement": ["song"],
    }


# ---------------------------------------------------------------------------
# Parse MIDI into voice events with the same code path ChipMood uses
# ---------------------------------------------------------------------------
def parse_lanes(seconds: float):
    notes = P.notes_from_midi(MIDI)
    if not notes:
        raise SystemExit(f"no notes in {MIDI}")
    max_beat = seconds * (BPM / 60.0)
    lane = {"lead": [], "harmony": [], "bass": [], "drums": []}
    names = ["lead", "harmony", "bass", "drums"]
    maxs = 0
    for (s16, d16, inst, p) in notes:
        start = s16 * (4.0 / P.STEPS_PER_BAR)
        if start > max_beat:
            continue
        dur = d16 * (4.0 / P.STEPS_PER_BAR)
        lane[names[inst]].append({
            "pitch": int(p),
            "start": round(start, 3),
            "duration": round(max(0.05, dur), 3),
            "velocity": VEL[names[inst]],
        })
        maxs = max(maxs, s16)
    bars = max(1, min(maxs // P.STEPS_PER_BAR + 1,
                       int(seconds * BPM / 60 / 4) + 2))
    return lane, bars


# ---------------------------------------------------------------------------
# Authentic NES softsynth (A)
# ---------------------------------------------------------------------------
def midi_hz(p: int) -> float:
    return 440.0 * (2.0 ** ((p - 69) / 12.0))


def render_nes(lane: dict, seconds: float) -> np.ndarray:
    """4-voice NES-style mix: 2 pulse + triangle + noise. True to NES-MDB."""
    n = int(seconds * SR)
    mix = np.zeros(n, dtype=np.float32)
    bps = BPM / 60.0

    def beats_to_samples(b: float) -> int:
        return int(b / bps * SR)

    # --- pulse voice (p1/p2) -------------------------------------------------
    def add_pulse(events, duty: float, vol: float, pan_l: float = 1.0):
        for e in events:
            s0 = beats_to_samples(e["start"])
            s1 = min(n, s0 + beats_to_samples(e["duration"]))
            if s1 <= s0:
                continue
            freq = midi_hz(e["pitch"])
            t = np.arange(s1 - s0, dtype=np.float32) / SR
            phase = (t * freq) % 1.0
            wave_ = np.where(phase < duty, 1.0, -1.0).astype(np.float32)
            # NES APU envelope: sharp attack, quick decay toward sustain
            env = np.ones_like(wave_)
            att = min(len(env), int(0.004 * SR))
            rel = min(len(env), int(0.05 * SR))
            if att > 1:
                env[:att] = np.linspace(0, 1, att, dtype=np.float32)
            if rel > 1:
                env[-rel:] *= np.linspace(1, 0, rel, dtype=np.float32)
            mix[s0:s1] += wave_ * env * vol * e["velocity"] * pan_l

    # --- triangle (bass) — NES triangle has 16 discrete levels ---------------
    def add_triangle(events, vol: float):
        for e in events:
            s0 = beats_to_samples(e["start"])
            s1 = min(n, s0 + beats_to_samples(e["duration"]))
            if s1 <= s0:
                continue
            freq = midi_hz(e["pitch"])
            t = np.arange(s1 - s0, dtype=np.float32) / SR
            phase = (t * freq) % 1.0
            # quantize to 16 levels like the real APU
            raw = 1.0 - 4.0 * np.abs(phase - 0.5)
            levels = np.round(raw * 7.5) / 7.5
            env = np.ones_like(levels)
            rel = min(len(env), int(0.04 * SR))
            if rel > 1:
                env[-rel:] *= np.linspace(1, 0, rel, dtype=np.float32)
            mix[s0:s1] += levels.astype(np.float32) * env * vol * e["velocity"]

    # --- noise (drums) -------------------------------------------------------
    def add_noise(events, vol: float):
        rng = np.random.default_rng(1)
        for e in events:
            s0 = beats_to_samples(e["start"])
            # Kick longer, hats short — pitch encodes drum type in our parse
            kind = e["pitch"]
            if kind <= 36:       # kick-ish
                length = min(int(0.12 * SR), n - s0)
                tone = 0.3
            elif kind <= 40:     # snare
                length = min(int(0.09 * SR), n - s0)
                tone = 0.6
            else:                # hat / other
                length = min(int(0.035 * SR), n - s0)
                tone = 0.9
            if length <= 0:
                continue
            # simple LFSR-ish noise via high-pass white
            noise = rng.standard_normal(length).astype(np.float32)
            # tone: low-pass for kick, bright for hat
            if tone < 0.5:
                # crude 1-pole LPF
                a = 0.15 + 0.5 * tone
                for i in range(1, length):
                    noise[i] = a * noise[i] + (1 - a) * noise[i - 1]
            env = np.exp(-np.linspace(0, 8 + 20 * (1 - tone), length)).astype(np.float32)
            # kick body: add a short sine drop
            if kind <= 36:
                t = np.arange(length, dtype=np.float32) / SR
                body = np.sin(2 * math.pi * (120 * np.exp(-t * 18)) * t)
                noise = 0.55 * noise + 0.7 * body.astype(np.float32)
            mix[s0:s0 + length] += noise * env * vol * e["velocity"]

    add_pulse(lane["lead"], duty=0.5, vol=0.22)
    add_pulse(lane["harmony"], duty=0.25, vol=0.14)
    add_triangle(lane["bass"], vol=0.28)
    add_noise(lane["drums"], vol=0.32)

    # Soft clip / normalize like a real APU mix
    peak = float(np.max(np.abs(mix)) + 1e-9)
    mix = np.tanh(mix / peak * 1.4) * 0.92
    return mix


def write_wav(path: str, audio: np.ndarray):
    pcm = np.clip(audio, -1, 1)
    pcm = (pcm * 32767).astype("<i2")
    with wave.open(path, "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())


def wav_to_mp3(wav: str, mp3: str):
    subprocess.check_call([
        "ffmpeg", "-y", "-v", "error", "-i", wav,
        "-codec:a", "libmp3lame", "-b:a", "192k", mp3,
    ])
    os.remove(wav)


# ---------------------------------------------------------------------------
# ChipMood engine path (B)
# ---------------------------------------------------------------------------
def render_app(lane: dict, bars: int) -> str:
    song = to_song(lane, bars, bpm=BPM,
                   title="Castlevania III Beginning (ChipMood)")
    jpath = os.path.join(OUT, "CastlevaniaIII_Beginning_app.json")
    with open(jpath, "w") as f:
        json.dump(song, f)
    mp3 = os.path.join(OUT, "B_CastlevaniaIII_Beginning_CHIPMOOD.mp3")
    subprocess.check_call([
        "cargo", "run", "--quiet", "--release", "--example", "render",
        "--", jpath, mp3, str(int(SECONDS)),
    ], cwd=os.path.join(ROOT, "..", "rust"))
    return mp3


def main():
    print("MIDI:", os.path.basename(MIDI))
    lane, bars = parse_lanes(SECONDS)
    print("voices:", {k: len(v) for k, v in lane.items()}, "bars", bars)

    print("--- A: authentic NES softsynth of the MIDI ---")
    audio = render_nes(lane, SECONDS)
    wav = os.path.join(OUT, "_tmp_a.wav")
    mp3_a = os.path.join(OUT, "A_CastlevaniaIII_Beginning_ORIGINAL.mp3")
    write_wav(wav, audio)
    wav_to_mp3(wav, mp3_a)
    print("wrote", mp3_a, os.path.getsize(mp3_a), "bytes")

    print("--- B: ChipMood Rust engine (same notes) ---")
    mp3_b = render_app(lane, bars)
    print("wrote", mp3_b, os.path.getsize(mp3_b), "bytes")

    print("DONE")
    print(mp3_a)
    print(mp3_b)


if __name__ == "__main__":
    main()
