"""Mine reusable, key-agnostic musical "parts" from BOTH datasets so EVERY voice
of EVERY track can be driven by real music (maximum originality):

  * grooves   : representative 1-bar drum beat (+ hiss..ring tone)
  * basslines : 1-bar bass rhythm + pitch contour
  * harmonies : 1-bar harmony/comp rhythm + contour
  * arps      : busy 1-bar arpeggio-like phrases (rhythm + contour)
  * melodies  : 1-bar lead phrases (rhythm + contour) for lead fallback
  * fills     : busy phrase-end drum sbivki
  * voicings  : real chord shapes for the pad

Contours are semitones relative to the phrase's first note, so the arranger
transposes them onto each track's key/chords. Output: assets/rag/grooves.json
"""
import ast, glob, io, json, os
from collections import Counter, defaultdict

import pretty_midi
import pyarrow.parquet as pq
from huggingface_hub import hf_hub_download

import prepare_data as P
import build_rag_vgm as V

ROOT = os.path.dirname(__file__)
OUT = os.path.join(ROOT, "..", "assets", "rag")
os.makedirs(OUT, exist_ok=True)
SPB = P.STEPS_PER_BAR
MAX_BARS = 48
VGM_SCAN = 3500
CAPS = dict(fills=280, voicings=64, grooves=260, basslines=220,
            harmonies=220, arps=200, melodies=220, profiles=600)


def fills_from(drum_notes):
    by_bar = defaultdict(list)
    for (s16, p) in drum_notes:
        b = s16 // SPB
        if b < MAX_BARS:
            by_bar[b].append((s16 % SPB, p))
    for hits in by_bar.values():
        second = [h for h in hits if h[0] >= SPB // 2]
        runs = [h for h in second if h[1] != 36]
        if len(hits) >= 7 and len(runs) >= 3:
            pat = sorted((pos / 4.0, pit) for (pos, pit) in set(hits))
            yield [[round(pos, 3), pit, 0.22, 0.9] for (pos, pit) in pat]


def voicings_from(lane_lists):
    active = {}
    for notes in lane_lists:
        for (s16, d16, p) in notes:
            for t in range(s16, s16 + max(1, d16)):
                active.setdefault(t, set()).add(p)
    out = []
    for pcs in active.values():
        if len(pcs) < 3:
            continue
        lo = min(pcs)
        iv = sorted({(p - lo) % 12 for p in pcs})
        if 3 <= len(iv) <= 4 and iv[0] == 0:
            out.append(tuple(iv))
    return out


def repr_bar(lane, min_hits):
    """Most-common 1-bar pattern of a lane -> list of (pos16, pitch, dur16, vel)."""
    by_bar = defaultdict(list)
    for (s16, d16, p, v) in lane:
        b = s16 // SPB
        if b < MAX_BARS:
            by_bar[b].append((s16 % SPB, p, max(1, d16), v))
    sigs, data = Counter(), {}
    for hits in by_bar.values():
        if len(hits) < min_hits:
            continue
        sig = tuple(sorted((pos, pit) for (pos, pit, _, _) in hits))
        sigs[sig] += 1
        data.setdefault(sig, sorted(hits))
    if not sigs:
        return None
    return data[sigs.most_common(1)[0][0]]


def groove_from(drum_lane):
    bar = repr_bar(drum_lane, 4)
    if not bar:
        return None
    hats = sum(1 for (_, pit, _, _) in bar if pit == 42)
    tone = round(min(1.0, 0.15 + 0.85 * (hats / len(bar))), 2)
    pat = [[round(pos / 4.0, 3), pit, round(min(2, d) / 4.0, 3), round(v, 2)]
           for (pos, pit, d, v) in bar]
    return {"p": pat, "tone": tone}


def contour_from(lane, min_hits, max_leap=24):
    """1-bar melodic pattern as [pos, semisFromFirst, dur, vel]."""
    bar = repr_bar(lane, min_hits)
    if not bar or len(bar) < 2:
        return None
    p0 = bar[0][1]
    pat = [[round(pos / 4.0, 3), pit - p0, round(min(8, d) / 4.0, 3), round(v, 2)]
           for (pos, pit, d, v) in bar]
    if any(abs(n[1]) > max_leap for n in pat):
        return None
    return pat


def add(pool, seen, item, key, cap):
    if item is None or len(pool) >= cap:
        return
    if key in seen:
        return
    seen.add(key)
    pool.append(item)


def profile_from(lanes):
    """A coherent production preset derived from a song's musical character:
    busy/bright -> driven, ringing, little space; sparse/legato -> clean, with
    tremolo, glide and echo. So RAG controls the knobs AND how many effects.

    NOTE: energy/legato use smooth saturating curves (1 - exp(-x)) instead of
    hard min() clamps. The old clamps saturated on almost every busy chiptune,
    so ~90% of the mined profiles came out with IDENTICAL knob values — which
    then made every generated track sound the same."""
    import math
    lead, harm, drums = lanes[0], lanes[1], lanes[3]
    if len(lead) < 6:
        return None
    bars = max(1, min(MAX_BARS, max((n[0] // SPB for n in lead), default=0) + 1))
    density = (len(lead) + len(harm)) / bars
    energy = 1.0 - math.exp(-density / 9.0)     # smooth 0..1, never flat-tops
    calm = 1.0 - energy
    hits = len(drums) or 1
    hatfrac = sum(1 for n in drums if n[2] == 42) / hits
    avgdur = sum(n[1] for n in lead) / len(lead)  # in 16ths -> legato measure
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
        # tracker per-note effect usage (the RAG decides how much of each)
        "vibAmt": round(0.2 + 0.6 * legato, 2),
        "slideAmt": round(0.1 + 0.4 * legato, 2),
        "retrigAmt": round(0.55 * energy, 2),
        "arpAmt": round(0.2 + 0.5 * energy, 2),
        # IT/Unreal-style resonant filter: more closed + resonant + sweep on
        # energetic/electronic material, open and clean on calm material.
        "cutoff": round(max(0.35, 1.0 - 0.5 * energy), 2),
        "resonance": round(0.2 + 0.6 * energy, 2),
        "filterEnv": round(0.25 + 0.6 * energy, 2),
    }


def harvest(lanes, P_, S):
    drum3 = [(s16, p) for (s16, d16, p, *_) in lanes[3]]
    for fill in fills_from(drum3):
        sig = tuple((round(x[0], 2), x[1]) for x in fill)
        add(P_["fills"], S["fills"], fill, sig, CAPS["fills"])
    melodic3 = [[(s, d, p) for (s, d, p, *_) in lanes[k]] for k in lanes if k != 3]
    for v in voicings_from(melodic3):
        P_["voic"][v] += 1
    g = groove_from(lanes[3])
    if g:
        add(P_["grooves"], S["grooves"], g, tuple((x[0], x[1]) for x in g["p"]),
            CAPS["grooves"])
    for name, lane, mn, key in (
        ("basslines", lanes[2], 2, "bass"),
        ("harmonies", lanes[1], 3, "harm"),
        ("melodies", lanes[0], 3, "mel"),
        ("arps", lanes[0], 6, "arp"),
    ):
        c = contour_from(lane, mn)
        if c:
            add(P_[name], S[key], c, tuple((x[0], x[1]) for x in c), CAPS[name])
    prof = profile_from(lanes)
    if prof is not None and len(P_["profiles"]) < CAPS["profiles"]:
        P_["profiles"].append(prof)


def nes_lanes(notes):
    lanes = {0: [], 1: [], 2: [], 3: []}
    for (s16, d16, inst, p) in notes:
        lanes[inst].append((s16, d16, p, 0.9))
    return lanes


def main():
    import random
    import warnings
    warnings.filterwarnings("ignore")
    P_ = {k: [] for k in CAPS if k != "voicings"}
    P_["voic"] = Counter()
    S = {k: set() for k in ("fills", "grooves", "bass", "harm", "mel", "arp")}

    # half the cap from NES (tight chiptune), rest from VGM (rich)
    half = {k: (v // 2 if k != "voicings" else v) for k, v in CAPS.items()}
    saved = dict(CAPS)
    CAPS.update(half)
    for f in sorted(glob.glob(os.path.join(ROOT, "nesmdb_midi", "*", "*.mid"))):
        try:
            notes = P.notes_from_midi(f)
        except Exception:
            continue
        if notes:
            harvest(nes_lanes(notes), P_, S)
    print("NES:", {k: len(P_[k]) for k in P_ if k != "voic"})
    CAPS.update(saved)

    scanned = 0
    try:
        for pqfile in V.PARQUETS:
            if scanned >= VGM_SCAN:
                break
            midis = pq.read_table(
                hf_hub_download(V.REPO, pqfile, repo_type="dataset")).column("midi")
            for i in range(len(midis)):
                if scanned >= VGM_SCAN:
                    break
                scanned += 1
                try:
                    b = ast.literal_eval(midis[i].as_py())
                    pm = pretty_midi.PrettyMIDI(io.BytesIO(b))
                    lanes, _ = V.extract_lanes(pm)
                except Exception:
                    continue
                if lanes:
                    harvest(lanes, P_, S)
    except Exception as e:
        print("VGM skipped:", e)
    print("VGM total:", {k: len(P_[k]) for k in P_ if k != "voic"})

    random.seed(0)
    for k in ("fills", "grooves", "basslines", "harmonies", "arps", "melodies",
              "profiles"):
        random.shuffle(P_[k])
    out = {
        "fills": P_["fills"][:CAPS["fills"]],
        "voicings": [list(v) for v, _ in P_["voic"].most_common(CAPS["voicings"])],
        "grooves": P_["grooves"][:CAPS["grooves"]],
        "basslines": P_["basslines"][:CAPS["basslines"]],
        "harmonies": P_["harmonies"][:CAPS["harmonies"]],
        "arps": P_["arps"][:CAPS["arps"]],
        "melodies": P_["melodies"][:CAPS["melodies"]],
        "profiles": P_["profiles"][:CAPS["profiles"]],
    }
    json.dump(out, open(os.path.join(OUT, "grooves.json"), "w"))
    print("FINAL:", {k: len(v) for k, v in out.items()})


if __name__ == "__main__":
    main()
