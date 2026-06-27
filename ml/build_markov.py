"""Learn an order-2 Markov model of MELODY from every RAG exemplar lead, so the
app can generate NEW, stylistically-coherent melodies (originality + per-track
variation) instead of replaying phrases verbatim — borrowed from the Markov
chiptune approach, but driven by our whole retrieval library.

Melody is represented as SCALE DEGREES (scale-steps from middle C), which keeps
generated lines in-key and lets the arranger anchor them to each bar's chord.
We also collect real 1-bar RHYTHMS (onset + duration) from the leads, so the
generator gets a human rhythmic feel and only the pitches are invented.

Output: assets/rag/markov.json
"""
import glob, json, os
from collections import Counter, defaultdict

ROOT = os.path.dirname(__file__)
RAG = os.path.join(ROOT, "..", "assets", "rag")
SCALE = {"major": [0, 2, 4, 5, 7, 9, 11], "minor": [0, 2, 3, 5, 7, 8, 10]}
DEG_LO, DEG_HI = -10, 17          # ~4 octaves of scale steps around middle C
MAX_TRANS = 1400                  # cap distinct (a,b) states for asset size
MAX_NEXT = 6                      # keep top-N continuations per state
MAX_RHYTHMS = 240


def pitch_to_degree(pitch, mode):
    pcs = SCALE[mode]
    oct_ = (pitch - 60) // 12
    pc = pitch % 12
    if pc in pcs:
        idx = pcs.index(pc)
    else:                          # snap to nearest scale tone
        idx = min(range(7), key=lambda i: min((pc - pcs[i]) % 12, (pcs[i] - pc) % 12))
    deg = oct_ * 7 + idx
    return max(DEG_LO, min(DEG_HI, deg))


def main():
    files = []
    for src in ("nes", "vgm", "ut", "pop", "emo", "vg", "ym"):
        files += glob.glob(os.path.join(RAG, f"{src}_exemplars.json"))
    trans = defaultdict(Counter)   # (a,b) -> Counter(c)
    starts = Counter()             # (a,b)
    rhythms = Counter()            # tuple of (pos,dur) per bar
    seen = 0
    for f in files:
        try:
            data = json.load(open(f))
        except Exception:
            continue
        for e in data:
            mode = e.get("scale", "minor")
            if mode not in SCALE:
                mode = "minor"
            lead = e.get("lead") or []
            if len(lead) < 4:
                continue
            seen += 1
            degs = [pitch_to_degree(int(n[1]), mode) for n in lead]
            if len(degs) >= 2:
                starts[(degs[0], degs[1])] += 1
            for i in range(2, len(degs)):
                trans[(degs[i - 2], degs[i - 1])][degs[i]] += 1
            # 1-bar rhythms (positions are in beats; split the phrase by bar)
            by_bar = defaultdict(list)
            for n in lead:
                pos = float(n[0])
                bar = int(pos // 4)
                dur = round(min(2.0, max(0.25, float(n[2]))), 2)
                by_bar[bar].append((round(pos - bar * 4, 2), dur))
            for hits in by_bar.values():
                if 1 <= len(hits) <= 10:
                    rhythms[tuple(sorted(hits))] += 1

    # serialize, capped
    top_states = [s for s, _ in
                  sorted(trans.items(), key=lambda kv: -sum(kv[1].values()))[:MAX_TRANS]]
    trans_out = {}
    for (a, b) in top_states:
        nxt = trans[(a, b)].most_common(MAX_NEXT)
        trans_out[f"{a},{b}"] = [[c, w] for c, w in nxt]
    starts_out = [[a, b, w] for (a, b), w in starts.most_common(400)]
    rhythms_out = [[list(p) for p in r] for r, _ in rhythms.most_common(MAX_RHYTHMS)]

    out = {
        "order": 2,
        "deg_lo": DEG_LO,
        "deg_hi": DEG_HI,
        "trans": trans_out,
        "starts": starts_out,
        "rhythms": rhythms_out,
    }
    json.dump(out, open(os.path.join(RAG, "markov.json"), "w"))
    print(f"leads={seen} states={len(trans_out)} starts={len(starts_out)} "
          f"rhythms={len(rhythms_out)}")
    size = os.path.getsize(os.path.join(RAG, "markov.json"))
    print("markov.json: %.1f KB" % (size / 1024))


if __name__ == "__main__":
    main()
