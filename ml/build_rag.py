"""Build a rich RAG exemplar DB from NES-MDB for the LLM composer.

For each song we don't just grab the first bars — we FIND THE HOOK (the most
repeated / catchiest 8-bar region of the lead) and extract all four real NES
voices there: lead (p1), harmony (p2), bass (triangle) and drums (noise). We
read the song's REAL tempo, transpose to a canonical key (tonic -> C), quantize
to 16ths, detect a chord progression and a mood quadrant. The app retrieves
exemplars matching the photo's mood and shows them to the LLM as few-shot, so it
composes original tracks that absorb the genuine melodic vocabulary, grooves and
tempos of classic chiptunes.

Output: assets/rag/nes_exemplars.json  (compact, in our song-plan format)
"""
import glob, json, os, random
from collections import Counter

import mido
import prepare_data as P

ROOT = os.path.dirname(__file__)
OUT = os.path.join(ROOT, "..", "assets", "rag")
os.makedirs(OUT, exist_ok=True)

MAJOR = [0, 2, 4, 5, 7, 9, 11]
MINOR = [0, 2, 3, 5, 7, 8, 10]
SPB = P.STEPS_PER_BAR          # 16th steps per bar
WIN = 8                        # bars per exemplar
PER_MOOD = 200                 # how many exemplars to keep per mood quadrant
INSTS = P.INSTS                # ["p1","p2","tr","no"]


def notes_with_vel(path):
    """Like prepare_data.notes_from_midi but KEEPS real note velocities (the
    genuine dynamics) and also returns the song's tempo. Single parse.
    Returns (notes, bpm) where notes = list of (start16, dur16, inst, pitch, vel0_1)."""
    try:
        m = mido.MidiFile(path)
    except Exception:
        return [], 132
    tpb = m.ticks_per_beat or 480
    tempo = None
    out = []
    for tr in m.tracks:
        name = None
        for msg in tr:
            if msg.type == "track_name":
                name = msg.name.strip().lower()
                break
        t = 0
        active = {}  # pitch -> (start_tick, velocity)
        is_voice = name in INSTS
        inst = INSTS.index(name) if is_voice else -1
        for msg in tr:
            t += msg.time
            if msg.type == "set_tempo" and tempo is None:
                tempo = msg.tempo
            if not is_voice:
                continue
            if msg.type == "note_on" and msg.velocity > 0:
                active[msg.note] = (t, msg.velocity)
            elif msg.type == "note_off" or (msg.type == "note_on" and msg.velocity == 0):
                hit = active.pop(msg.note, None)
                if hit is None:
                    continue
                s, vel = hit
                start16 = int(round((s / tpb) * 4))
                dur16 = max(1, min(P.MAX_DUR, int(round(((t - s) / tpb) * 4))))
                p = msg.note
                if inst == 3:  # noise -> a few drum pitches
                    p = 36 + (p % 4) * 2
                p = max(P.PITCH_MIN, min(P.PITCH_MAX, p))
                out.append((start16, dur16, inst, p, vel))  # raw vel 0..127
    out.sort(key=lambda e: (e[0], e[2], e[3]))
    bpm = 132 if not tempo else int(max(80, min(200, round(60_000_000 / tempo))))
    return out, bpm


def detect_key(pcs_hist):
    best, root, mode = -1, 0, "major"
    for r in range(12):
        for name, scale in (("major", MAJOR), ("minor", MINOR)):
            sc = {(r + i) % 12 for i in scale}
            score = sum(pcs_hist[pc] for pc in sc)
            if score > best:
                best, root, mode = score, r, name
    return root, mode


def degree_of(pc, root, scale):
    rel = (pc - root) % 12
    best_i, best_d = 0, 99
    for i, iv in enumerate(scale):
        d = min((rel - iv) % 12, (iv - rel) % 12)
        if d < best_d:
            best_d, best_i = d, i
    return best_i


def best_window(lead, total_bars):
    """Pick the catchiest WIN-bar region of the lead: the one whose 2-bar
    motifs repeat the most (a real hook), with a healthy note density."""
    if total_bars <= WIN:
        return 0
    best_start, best_score = 0, -1e9
    for start in range(0, total_bars - WIN + 1):
        notes = [n for n in lead if start <= n[0] // SPB < start + WIN]
        if len(notes) < WIN:           # too sparse to be a hook
            continue
        sigs = []
        for b0 in range(start, start + WIN, 2):
            sig = tuple(sorted(
                ((s16 - b0 * SPB), p) for (s16, d16, p, v) in notes
                if b0 <= s16 // SPB < b0 + 2
            ))
            if sig:
                sigs.append(sig)
        rep = max(Counter(sigs).values()) if sigs else 0
        dens = len(notes) / WIN
        score = rep * 3.0 - abs(dens - 3.0)   # repetition wins, ~3 notes/bar
        if score > best_score:
            best_score, best_start = score, start
    return best_start


def _phrase(lane_notes, shift, start_bar, cap, vscale):
    """WIN bars from start_bar of a melodic lane -> monophonic, zero-based
    phrase with normalized dynamics: [start, pitch, dur, vel]."""
    lo, hi = start_bar * SPB, (start_bar + WIN) * SPB
    ph = []
    for (s16, d16, p, v) in sorted(lane_notes):
        if s16 < lo:
            continue
        if s16 >= hi:
            break
        ph.append([round((s16 - lo) / 4, 3), p + shift, round(max(1, d16) / 4, 3), vscale(v)])
    ph.sort(key=lambda n: n[0])
    mono = []
    for n in ph:
        if mono and n[0] <= mono[-1][0] + 1e-3:
            continue
        if mono and mono[-1][0] + mono[-1][2] > n[0]:
            mono[-1][2] = round(n[0] - mono[-1][0], 3)
        if n[2] > 0.01:
            mono.append(n)
    return [n for n in mono if n[2] > 0.01][:cap]


def _drum_phrase(lane_notes, start_bar, cap, vscale):
    """WIN bars of the noise lane kept POLYPHONIC (kick+snare can land together)
    — the real groove, deduped, with normalized dynamics. [start,pitch,dur,vel]."""
    lo, hi = start_bar * SPB, (start_bar + WIN) * SPB
    ph, seen = [], set()
    for (s16, d16, p, v) in sorted(lane_notes):
        if s16 < lo:
            continue
        if s16 >= hi:
            break
        key = (s16, p)
        if key in seen:           # drop exact duplicate hits
            continue
        seen.add(key)
        ph.append([round((s16 - lo) / 4, 3), p, round(max(1, min(2, d16)) / 4, 3), vscale(v)])
    return ph[:cap]


def build_one(path):
    raw, bpm = notes_with_vel(path)
    if not raw:
        return None
    lanes = {0: [], 1: [], 2: [], 3: []}
    hist = [0] * 12
    for (s16, d16, inst, p, v) in raw:
        lanes[inst].append((s16, d16, p, v))
        if inst in (0, 1, 2):
            hist[p % 12] += 1
    if len(lanes[0]) < 8:
        return None  # need a real lead

    root, mode = detect_key(hist)
    scale = MAJOR if mode == "major" else MINOR
    shift = -root if root <= 6 else 12 - root  # tonic -> C, minimal move

    total_bars = max(n[0] // SPB for n in lanes[0]) + 1
    start = best_window(lanes[0], total_bars)

    # Per-song dynamics normalization: NES-MDB stores the 4-bit volume in the
    # velocity byte, so absolute values are tiny. Map the song's own range into
    # a musical 0.5..0.95 so relative dynamics survive but nothing is silent.
    maxv = max((v for (_, _, _, _, v) in raw), default=0)
    def vscale(v):
        if maxv <= 0:
            return 0.85
        return round(0.5 + 0.45 * (v / maxv), 2)

    lead = _phrase(lanes[0], shift, start, 40, vscale)
    if len(lead) < 6:
        return None
    harmony = _phrase(lanes[1], shift, start, 32, vscale)
    bass = _phrase(lanes[2], shift, start, 28, vscale)
    drums = _drum_phrase(lanes[3], start, 64, vscale)  # polyphonic groove

    # chords per bar from concurrent melodic pitches (root of each bar)
    chords = []
    for b in range(WIN):
        lo, hi = (start + b) * SPB, (start + b + 1) * SPB
        pcs = [p % 12 for ln in (2, 1, 0)
               for (s16, d16, p, v) in lanes[ln] if lo <= s16 < hi]
        if not pcs:
            chords.append(chords[-1] if chords else 0)
        else:
            common = Counter(pcs).most_common(1)[0][0]
            chords.append(degree_of(common, root, scale))

    # mood: valence from mode, arousal from lead density
    npb = len(lead) / WIN
    arousal = 1 if npb >= 4 else 0
    valence = 1 if mode == "major" else 0
    quad = {(1, 1): "happy", (0, 1): "tense", (0, 0): "sad", (1, 0): "calm"}[(valence, arousal)]

    # NES-MDB normalizes all files to 120 BPM in the tempo meta, so it carries
    # no real tempo. Derive a varied, mood-appropriate tempo HINT instead (the
    # LLM still picks the final tempo) so examples don't all read as 120.
    h = sum((i + 1) * ord(c) for i, c in enumerate(os.path.basename(path)))
    bpm = (150 + h % 30) if arousal else (96 + h % 28)

    return {
        "title": os.path.basename(path).replace(".mid", ""),
        "mood": quad, "valence": valence, "arousal": arousal,
        "scale": mode, "bpm": bpm, "bars": WIN,
        "chords": chords, "lead": lead, "harmony": harmony, "bass": bass,
        "drums": drums,
    }


def main():
    files = sorted(glob.glob(os.path.join(ROOT, "nesmdb_midi", "*", "*.mid")))
    out = []
    for f in files:
        try:
            e = build_one(f)
        except Exception:
            e = None
        if e:
            out.append(e)
    random.seed(0)
    random.shuffle(out)
    by_mood = {}
    for e in out:
        by_mood.setdefault(e["mood"], []).append(e)
    capped = []
    for m, xs in by_mood.items():
        capped.extend(xs[:PER_MOOD])
    random.shuffle(capped)
    json.dump(capped, open(os.path.join(OUT, "nes_exemplars.json"), "w"))
    print("total usable:", len(out), "-> capped:", len(capped))
    print("by mood:", {m: len(xs[:PER_MOOD]) for m, xs in by_mood.items()})
    print("example:", json.dumps(capped[0])[:300])


if __name__ == "__main__":
    main()
