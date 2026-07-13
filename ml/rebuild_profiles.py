"""Regenerate ONLY the 'profiles' array of assets/rag/grooves.json from the
local NES-MDB MIDIs, using the smooth (non-saturating) formula in
build_grooves.profile_from. The old asset was mined with hard min() clamps, so
~90% of profiles came out with IDENTICAL knob values — every generated track
inherited the same sound design. Run: /tmp/mlvenv/bin/python ml/rebuild_profiles.py
"""
import glob, json, math, os, random

import prepare_data as P

SPB = P.STEPS_PER_BAR
MAX_BARS = 48


def nes_lanes(notes):
    lanes = {0: [], 1: [], 2: [], 3: []}
    for (s16, d16, inst, p) in notes:
        lanes[inst].append((s16, d16, p, 0.9))
    return lanes


def profile_from(lanes):
    """Copy of build_grooves.profile_from (smooth saturation), kept local so
    this script doesn't pull the heavy pyarrow/huggingface deps."""
    lead, harm, drums = lanes[0], lanes[1], lanes[3]
    if len(lead) < 6:
        return None
    bars = max(1, min(MAX_BARS, max((n[0] // SPB for n in lead), default=0) + 1))
    density = (len(lead) + len(harm)) / bars
    energy = 1.0 - math.exp(-density / 9.0)
    calm = 1.0 - energy
    hits = len(drums) or 1
    hatfrac = sum(1 for n in drums if n[2] == 42) / hits
    avgdur = sum(n[1] for n in lead) / len(lead)
    legato = 1.0 - math.exp(-avgdur / 5.0)
    return {
        "drumsTone": round(min(1.0, 0.12 + 0.85 * hatfrac), 2),
        "percTone": round(min(1.0, 0.45 + 0.5 * hatfrac), 2),
        "leadDrive": round(0.05 + 0.65 * energy * energy, 2),
        "bassDrive": round(0.45 * energy, 2),
        "leadCrush": round(0.3 * energy * (1 if hatfrac < 0.3 else 0), 2),
        "leadGlide": round(0.8 * legato, 2),
        "padTrem": round(0.6 * calm, 2),
        "arpTrem": round(0.45 * calm, 2),
        "delay": round(0.12 + 0.45 * calm, 2),
        "vibAmt": round(0.2 + 0.6 * legato, 2),
        "slideAmt": round(0.1 + 0.4 * legato, 2),
        "retrigAmt": round(0.55 * energy, 2),
        "arpAmt": round(0.2 + 0.5 * energy, 2),
        "cutoff": round(max(0.35, 1.0 - 0.5 * energy), 2),
        "resonance": round(0.2 + 0.6 * energy, 2),
        "filterEnv": round(0.25 + 0.6 * energy, 2),
    }

ROOT = os.path.dirname(__file__)
ASSET = os.path.join(ROOT, "..", "assets", "rag", "grooves.json")
CAP = 600


def main():
    profiles = []
    files = sorted(glob.glob(os.path.join(ROOT, "nesmdb_midi", "*", "*.mid")))
    for f in files:
        try:
            notes = P.notes_from_midi(f)
        except Exception:
            continue
        if not notes:
            continue
        lanes = nes_lanes(notes)
        prof = profile_from(lanes)
        if prof is not None:
            profiles.append(prof)

    # Dedupe exact duplicates, then shuffle deterministically and cap.
    seen, uniq = set(), []
    for p in profiles:
        k = json.dumps(p, sort_keys=True)
        if k in seen:
            continue
        seen.add(k)
        uniq.append(p)
    random.seed(7)
    random.shuffle(uniq)
    uniq = uniq[:CAP]

    data = json.load(open(ASSET))
    old = len(data.get("profiles", []))
    data["profiles"] = uniq
    json.dump(data, open(ASSET, "w"))
    print(f"profiles: {old} -> {len(uniq)} (unique, smooth formula)")

    # quick spread report
    import statistics
    for k in ("leadDrive", "cutoff", "resonance", "filterEnv", "arpAmt",
              "drumsTone", "vibAmt", "delay"):
        vals = [p[k] for p in uniq if k in p]
        print("%-10s min=%.2f med=%.2f max=%.2f distinct=%d" % (
            k, min(vals), statistics.median(vals), max(vals),
            len(set(round(v, 2) for v in vals))))


if __name__ == "__main__":
    main()
