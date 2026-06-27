"""Export a WHOLE tracker module (e.g. Foregone) as a full song-plan JSON in our
engine's contract, so we can render it through OUR Rust synth and A/B it against
the original. Keeps the ORIGINAL key (no transpose) and the real tempo; reduces
the module's many channels to our lead/counter/harmony/bass/drums voices, lays
the entire song into one pattern, and uses sensible chip instrument settings."""
import json, os, sys, zipfile

import build_ut as U
import prepare_data as P

ROOT = os.path.dirname(__file__)
PK3 = os.path.join(ROOT, "..", "U1+UT99 music.pk3")
SPB = U.SPB
MAX_BARS = 160                         # ~ up to a few minutes


def voice_notes(lane, vol_scale, max_dur=P.MAX_DUR):
    out = []
    for (s16, d16, p, v) in sorted(lane):
        if s16 // SPB >= MAX_BARS:
            break
        out.append({
            "pitch": int(p),
            "start": round(s16 / 4.0, 4),
            "duration": round(max(1, min(max_dur, d16)) / 4.0, 4),
            "velocity": round(vol_scale(v), 3),
        })
    return out


def main():
    name = sys.argv[1] if len(sys.argv) > 1 else "Foregone"
    out_path = sys.argv[2] if len(sys.argv) > 2 else os.path.join(
        ROOT, "..", "reference", f"{name}_plan.json")

    with zipfile.ZipFile(PK3) as z:
        member = next(n for n in z.namelist()
                      if n.lower().endswith(".s3m") and name.lower() in n.lower())
        data = z.read(member)
    parsed = U.parse_it(data) if data[:4] == b"IMPM" else U.parse_s3m(data)
    if parsed is None:
        raise SystemExit("could not parse module")

    # Reuse the same voice selection the RAG uses (lead/harmony/counter/bass).
    chan_mel = parsed["chan_mel"]
    stats = []
    for ch, mel in chan_mel.items():
        pits = [n[2] for n in mel]
        stats.append(dict(ch=ch, mel=mel, mean=sum(pits) / len(pits),
                          n=len(mel), score=U.melodic_score(mel)))
    stats.sort(key=lambda s: s["mean"])
    med = stats[len(stats) // 2]["mean"]
    max_n = max(s["n"] for s in stats)
    # bass = lowest-register channel that is actually ACTIVE (avoid a sparse
    # sub-drop channel); require a reasonable note count.
    active = [s for s in stats if s["n"] >= max(16, 0.2 * max_n)] or stats
    bass_s = min(active, key=lambda s: s["mean"])
    bass = bass_s["mel"]; used = {bass_s["ch"]}
    upper = [s for s in stats if s["mean"] >= med and s["ch"] not in used] or \
            [s for s in stats if s["ch"] not in used]
    lead_s = max(upper, key=lambda s: s["score"]); lead = lead_s["mel"]
    used.add(lead_s["ch"])
    rest = [s for s in stats if s["ch"] not in used]
    harmony = max(rest, key=lambda s: s["n"])["mel"] if rest else []
    if rest:
        used.add(max(rest, key=lambda s: s["n"])["ch"])
    rest2 = [s for s in stats if s["ch"] not in used]
    counter = max(rest2, key=lambda s: s["score"])["mel"] if rest2 else []
    drums = []
    seen = set()
    for (s, p, v) in sorted(parsed["drum_lane"]):
        if (s, p) in seen:
            continue
        seen.add((s, p))
        drums.append((s, 1, p, v))

    allv = [v for lane in (lead, harmony, counter, bass)
            for (_, _, _, v) in lane] + [v for (_, _, _, v) in drums]
    maxv = max(allv) if allv else 0

    def vs(v):
        return 0.8 if maxv <= 0 else round(max(0.4, 0.45 + 0.5 * (v / maxv)), 3)

    bpm = int(max(70, min(200, parsed["tempo"] or 125)))
    bank_path = os.path.abspath(
        os.path.join(ROOT, "..", "assets", "samples", "ut_bank.bin"))
    plan = {
        "title": f"{name} (our engine)",
        "bpm": bpm,
        "sample_rate": 44100,
        "master_volume": 0.85,
        "delay_wet": 0.18,
        "sample_bank": bank_path,
        "instruments": [
            {"id": "lead", "waveform": "pulse", "duty": 0.5, "volume": 0.8,
             "pan": 0.12, "sample": "melodic0",
             "envelope": {"attack": 0.004, "decay": 0.05, "sustain": 0.6, "release": 0.12}},
            {"id": "counter", "waveform": "pulse", "duty": 0.25, "volume": 0.62,
             "pan": -0.14, "sample": "melodic1",
             "envelope": {"attack": 0.004, "decay": 0.06, "sustain": 0.5, "release": 0.12}},
            {"id": "harmony", "waveform": "pulse", "duty": 0.25, "volume": 0.5,
             "pan": -0.2, "sample": "melodic2",
             "envelope": {"attack": 0.006, "decay": 0.08, "sustain": 0.45, "release": 0.14}},
            {"id": "bass", "waveform": "triangle", "volume": 0.9, "pan": 0.0,
             "sample": "bass0",
             "envelope": {"attack": 0.004, "decay": 0.06, "sustain": 0.8, "release": 0.1}},
            {"id": "drums", "waveform": "noise", "volume": 0.95, "tone": 0.5,
             "sample": "@kit",
             "envelope": {"attack": 0.001, "decay": 0.05, "sustain": 1.0, "release": 0.05}},
        ],
        "patterns": [{
            "id": "song",
            "tracks": [
                {"instrument": "lead", "notes": voice_notes(lead, vs)},
                {"instrument": "counter", "notes": voice_notes(counter, vs)},
                {"instrument": "harmony", "notes": voice_notes(harmony, vs)},
                {"instrument": "bass", "notes": voice_notes(bass, vs)},
                {"instrument": "drums", "notes": voice_notes(drums, vs, max_dur=2)},
            ],
        }],
        "arrangement": ["song"],
    }

    json.dump(plan, open(out_path, "w"))
    total_beats = max((n["start"] + n["duration"])
                      for t in plan["patterns"][0]["tracks"] for n in t["notes"])
    secs = total_beats / bpm * 60.0
    nnotes = sum(len(t["notes"]) for t in plan["patterns"][0]["tracks"])
    print(f"wrote {out_path}  bpm={bpm} notes={nnotes} "
          f"~{secs:.0f}s lead={len(lead)} bass={len(bass)} drums={len(drums)}")


if __name__ == "__main__":
    main()
