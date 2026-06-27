"""Mine the REAL Unreal / UT99 soundtrack into RAG exemplars.

The "U1+UT99 music.pk3" holds 80 modules by pro demoscene composers (Alexander
Brandon, Michiel van den Bos, Andrew Sega/Necros, Dan Gardopee...): a mix of
Scream Tracker 3 (.s3m, "SCRM") and Impulse Tracker (.it, "IMPM") files plus a
couple of rendered OGGs we skip. They are the user's gold standard: 16-32 voices,
long through-composed forms, beautiful leads and grooves.

We parse the modules ourselves (header, order list, instrument/sample names,
packed pattern note data), reduce the many channels to our voice schema
(lead / harmony / counter / bass / drums) using register + MELODIC-VARIETY +
name heuristics, normalize to key C, find the catchiest 8-bar hook, read the
real tempo, tag a mood. We also distil the order lists into reusable
through-composed STRUCTURE templates.

Outputs:
  assets/rag/ut_exemplars.json   (compact, source='ut')
  assets/rag/ut_structures.json  (real song forms, e.g. "ABCBDCE...")
"""
import json, os, zipfile
from collections import Counter, defaultdict

import build_rag as B
import prepare_data as P

ROOT = os.path.dirname(__file__)
PK3 = os.path.join(ROOT, "..", "U1+UT99 music.pk3")
OUT = os.path.join(ROOT, "..", "assets", "rag")
os.makedirs(OUT, exist_ok=True)

SPB = B.SPB
MAX_ROWS = 320 * 16
PER_MOOD = 200


def u16(b, o):
    return b[o] | (b[o + 1] << 8)


def u32(b, o):
    return b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)


def drum_pitch(name):
    """Map a sample/instrument name to kick/snare/hat/tom, or None if melodic."""
    n = name.lower()
    if any(k in n for k in ("kick", "kik", "bdrum", "bass drum", "bassdr", "bd.",
                            "bd ", "bassd", "bassk")):
        return 36
    if any(k in n for k in ("snare", "snr", "sna", "sd.", "sd ", "clap", "clp",
                            "rim")):
        return 38
    if any(k in n for k in ("hat", "hh", "hi-hat", "hihat", "cymb", "ride",
                            "crash", "shaker", "tamb", "chink")):
        return 42
    if any(k in n for k in ("tom", "conga", "bongo", "timp", "tymp", "perc")):
        return 40
    if any(k in n for k in ("drum", "beat", "drm")):     # generic -> tom-ish
        return 40
    return None


def is_drum_name(name):
    return drum_pitch(name) is not None


# ---------------------------------------------------------------- S3M ---------
def s3m_unpack(data, ptr):
    off = ptr * 16
    if ptr == 0 or off + 2 > len(data):
        return None
    pos = off + 2
    rows = [dict() for _ in range(64)]
    row = 0
    while row < 64 and pos < len(data):
        what = data[pos]
        pos += 1
        if what == 0:
            row += 1
            continue
        chan = what & 31
        note = ins = vol = None
        if what & 32:
            if pos + 1 >= len(data):
                break
            note, ins = data[pos], data[pos + 1]
            pos += 2
        if what & 64:
            if pos >= len(data):
                break
            vol = data[pos]
            pos += 1
        if what & 128:
            pos += 2
        rows[row][chan] = (note, ins, vol)
    return rows


def parse_s3m(data):
    if len(data) < 0x60 or data[0x2C:0x30] != b"SCRM":
        return None
    title = data[0:28].split(b"\0")[0].decode("latin1", "ignore").strip()
    ordnum, insnum, patnum = u16(data, 0x20), u16(data, 0x22), u16(data, 0x24)
    tempo = data[0x32]
    p = 0x60
    orders = list(data[p:p + ordnum]); p += ordnum
    ins_ptrs = [u16(data, p + 2 * i) for i in range(insnum)]; p += 2 * insnum
    pat_ptrs = [u16(data, p + 2 * i) for i in range(patnum)]

    dtone = []
    for ip in ins_ptrs:
        o = ip * 16
        nm = ""
        if 0 < o and o + 0x4C <= len(data):
            nm = data[o + 0x30:o + 0x4C].split(b"\0")[0].decode("latin1", "ignore")
        dtone.append(drum_pitch(nm))

    pats = [s3m_unpack(data, pp) for pp in pat_ptrs]
    timeline = []
    for o in orders:
        if o >= 254 or o >= len(pats) or pats[o] is None:
            continue
        timeline.extend(pats[o])
        if len(timeline) >= MAX_ROWS:
            break
    if len(timeline) < SPB * 4:
        return None

    chan_evt = defaultdict(list)
    for s16, rm in enumerate(timeline):
        for ch, (note, ins, vol) in rm.items():
            chan_evt[ch].append((s16, note, ins, vol))
    chan_mel, drum_lane = {}, []
    for ch, evs in chan_evt.items():
        mel, dr = s3m_channel(evs, dtone)
        if mel:
            chan_mel[ch] = mel
        drum_lane.extend(dr)
    return dict(title=title, tempo=tempo, orders=orders, patnum=patnum,
                chan_mel=chan_mel, drum_lane=drum_lane)


def s3m_channel(events, dtone):
    """S3M note byte: 0xFF none, 0xFE cut, else octave=hi nibble, semi=lo nibble."""
    mel, dr = [], []
    cur, last_ins = None, None

    def close(end):
        if cur:
            mel.append((cur[0], max(1, min(P.MAX_DUR, end - cur[0])), cur[1], cur[2]))

    for (s16, note, ins, vol) in events:
        if ins:
            last_ins = ins
        use = ins if ins else last_ins
        if note is None or note == 255:
            continue
        if note == 254:
            close(s16); cur = None; continue
        octave, semi = note >> 4, note & 15
        if semi > 11:
            continue
        midi = max(P.PITCH_MIN, min(P.PITCH_MAX, octave * 12 + semi + 12))
        vel = min(127, (vol if vol is not None else 48) * 2)
        tone = dtone[use - 1] if (use and use - 1 < len(dtone)) else None
        if tone is not None:
            dr.append((s16, tone, vel))
        else:
            close(s16); cur = (s16, midi, vel)
    close(events[-1][0] + 2 if events else 0)
    return mel, dr


# ---------------------------------------------------------------- IT ----------
def it_unpack(data, off, channels=64):
    if off + 8 > len(data):
        return None
    length = u16(data, off)
    rows = u16(data, off + 2)
    pos = off + 8
    end = min(len(data), pos + length)
    grid = [dict() for _ in range(rows)]
    last_mask = [0] * channels
    last_note = [None] * channels
    last_ins = [None] * channels
    last_vol = [None] * channels
    row = 0
    while row < rows and pos < end:
        cv = data[pos]; pos += 1
        if cv == 0:
            row += 1; continue
        ch = (cv - 1) & 63
        if cv & 128:
            if pos >= end:
                break
            last_mask[ch] = data[pos]; pos += 1
        mask = last_mask[ch]
        note = ins = vol = None
        if mask & 1:
            note = data[pos]; pos += 1; last_note[ch] = note
        if mask & 2:
            ins = data[pos]; pos += 1; last_ins[ch] = ins
        if mask & 4:
            vol = data[pos]; pos += 1; last_vol[ch] = vol
        if mask & 8:
            pos += 2
        if mask & 16:
            note = last_note[ch]
        if mask & 32:
            ins = last_ins[ch]
        if mask & 64:
            vol = last_vol[ch]
        grid[row][ch] = (note, ins, vol)
    return grid


def parse_it(data):
    if len(data) < 0xC0 or data[0:4] != b"IMPM":
        return None
    title = data[4:30].split(b"\0")[0].decode("latin1", "ignore").strip()
    ordnum, insnum, smpnum, patnum = (u16(data, 0x20), u16(data, 0x22),
                                      u16(data, 0x24), u16(data, 0x26))
    tempo = data[0x33]
    p = 0xC0
    orders = list(data[p:p + ordnum]); p += ordnum
    ins_off = [u32(data, p + 4 * i) for i in range(insnum)]; p += 4 * insnum
    smp_off = [u32(data, p + 4 * i) for i in range(smpnum)]; p += 4 * smpnum
    pat_off = [u32(data, p + 4 * i) for i in range(patnum)]

    # instruments map to drum-ness via their name (IMPI name at +0x20, 26 bytes)
    dtone = []
    for io in ins_off:
        nm = ""
        if 0 < io and io + 0x3A <= len(data) and data[io:io + 4] == b"IMPI":
            nm = data[io + 0x20:io + 0x3A].split(b"\0")[0].decode("latin1", "ignore")
        dtone.append(drum_pitch(nm))
    # if no instruments (sample-mode IT), fall back to sample names (IMPS +0x14)
    if not any(t is not None for t in dtone):
        sd = []
        for so in smp_off:
            nm = ""
            if 0 < so and so + 0x2E <= len(data) and data[so:so + 4] == b"IMPS":
                nm = data[so + 0x14:so + 0x2E].split(b"\0")[0].decode("latin1", "ignore")
            sd.append(drum_pitch(nm))
        dtone = sd

    timeline = []
    for o in orders:
        if o >= 254 or o >= len(pat_off):
            continue
        po = pat_off[o]
        if po == 0 or po + 8 > len(data):
            continue
        grid = it_unpack(data, po)
        if grid:
            timeline.extend(grid)
        if len(timeline) >= MAX_ROWS:
            break
    if len(timeline) < SPB * 4:
        return None

    chan_evt = defaultdict(list)
    for s16, rm in enumerate(timeline):
        for ch, (note, ins, vol) in rm.items():
            chan_evt[ch].append((s16, note, ins, vol))
    chan_mel, drum_lane = {}, []
    for ch, evs in chan_evt.items():
        mel, dr = it_channel(evs, dtone)
        if mel:
            chan_mel[ch] = mel
        drum_lane.extend(dr)
    return dict(title=title, tempo=tempo, orders=orders, patnum=patnum,
                chan_mel=chan_mel, drum_lane=drum_lane)


def it_channel(events, dtone):
    """IT note byte: 0..119 note (60=C-5), 254 cut, 255 off, >=246 special."""
    mel, dr = [], []
    cur, last_ins = None, None

    def close(end):
        if cur:
            mel.append((cur[0], max(1, min(P.MAX_DUR, end - cur[0])), cur[1], cur[2]))

    for (s16, note, ins, vol) in events:
        if ins:
            last_ins = ins
        use = ins if ins else last_ins
        if note is None:
            continue
        if note >= 120:                            # cut / off / fade
            close(s16); cur = None; continue
        midi = max(P.PITCH_MIN, min(P.PITCH_MAX, note + 12))
        # IT volume column 0..64 = volume; 128..192 = panning (ignore as vol)
        v = vol if (vol is not None and vol <= 64) else 48
        vel = min(127, v * 2)
        tone = dtone[use - 1] if (use and use - 1 < len(dtone)) else None
        if tone is not None:
            dr.append((s16, tone, vel))
        else:
            close(s16); cur = (s16, midi, vel)
    close(events[-1][0] + 2 if events else 0)
    return mel, dr


# ----------------------------------------------------- shared exemplar build --
def melodic_score(mel):
    """How 'singable' a line is: rewards pitch variety and a ~1-octave range,
    penalises drones (tiny motion) and leapy/arpeggio lines (big jumps). Used to
    pick the LEAD so we get real melodies, not ostinatos or arpeggios."""
    pits = [n[2] for n in mel]
    if len(pits) < 8:
        return -1e9
    uniq = len(set(pits))
    rng = max(pits) - min(pits)
    leaps = [abs(pits[i + 1] - pits[i]) for i in range(len(pits) - 1)]
    avg = sum(leaps) / len(leaps)
    bigfrac = sum(1 for l in leaps if l > 7) / len(leaps)
    score = min(uniq, 10) * 1.0
    score -= abs(rng - 14) * 0.22       # ideal range ~ an octave + a bit
    score -= max(0.0, avg - 4.0) * 1.5  # too leapy -> arpeggio, not melody
    score -= max(0.0, 1.5 - avg) * 2.5  # too static -> a drone/pedal
    score -= bigfrac * 9.0              # frequent big jumps -> not a melody
    return score


def is_real_melody(phrase):
    pits = [n[1] for n in phrase]
    if len(set(pits)) < 4:
        return False
    rng = max(pits) - min(pits)
    if rng < 3 or rng > 30:
        return False
    leaps = [abs(pits[i + 1] - pits[i]) for i in range(len(pits) - 1)]
    if leaps and sum(leaps) / len(leaps) > 6.5:
        return False
    return True


def best_mel_window(lead_lane, total_bars):
    """Pick the most SINGABLE WIN-bar window of the lead (best melodic_score),
    so the exemplar's hook is a real melody, not a static or arpeggiated patch."""
    if total_bars <= B.WIN:
        return 0
    best, bs = -1e9, 0
    for start in range(0, total_bars - B.WIN + 1):
        notes = [n for n in lead_lane if start <= n[0] // SPB < start + B.WIN]
        if len(notes) < B.WIN:
            continue
        sc = melodic_score(notes)               # notes are (s16,d16,pitch,vel)
        if sc > best:
            best, bs = sc, start
    return bs


def best_region(lead_lane, total_bars, region_bars):
    """Pick the most melodic CONTIGUOUS region of `region_bars` bars — this is a
    real multi-section stretch of the track (verse->chorus->bridge), which we
    then split into distinct 4-bar parts so songs are through-composed, not a
    single looped idea."""
    if total_bars <= region_bars:
        return 0
    best, bs = -1e9, 0
    for start in range(0, total_bars - region_bars + 1, 4):
        notes = [n for n in lead_lane if start <= n[0] // SPB < start + region_bars]
        if len(notes) < region_bars:
            continue
        if melodic_score(notes) > best:
            best, bs = melodic_score(notes), start
    return bs


def slice_phrase(lane, shift, lo_bar, bars, cap, vscale, mono=True):
    """A `bars`-long window of a lane, re-zeroed to position 0, optionally forced
    monophonic. Positions/durations in beats; pitches transposed by `shift`."""
    lo, hi = lo_bar * SPB, (lo_bar + bars) * SPB
    ph = []
    for (s16, d16, p, v) in sorted(lane):
        if s16 < lo:
            continue
        if s16 >= hi:
            break
        ph.append([round((s16 - lo) / 4, 3), p + shift,
                   round(max(1, d16) / 4, 3), vscale(v)])
    ph.sort(key=lambda n: n[0])
    if not mono:
        return ph[:cap]
    out = []
    for n in ph:
        if out and n[0] <= out[-1][0] + 1e-3:
            continue
        if out and out[-1][0] + out[-1][2] > n[0]:
            out[-1][2] = round(n[0] - out[-1][0], 3)
        if n[2] > 0.01:
            out.append(n)
    return [n for n in out if n[2] > 0.01][:cap]


def chords_of(lanes, root, scale, lo_bar, bars):
    out = []
    for b in range(bars):
        lo, hi = (lo_bar + b) * SPB, (lo_bar + b + 1) * SPB
        pcs = [p % 12 for ln in (2, 1, 0)
               for (s16, d16, p, v) in lanes[ln] if lo <= s16 < hi]
        out.append(B.degree_of(Counter(pcs).most_common(1)[0][0], root, scale)
                   if pcs else (out[-1] if out else 0))
    return out


def build_one(name, source, parsed):
    chan_mel = parsed["chan_mel"]
    if len(chan_mel) < 2:
        return None

    stats = []
    for ch, mel in chan_mel.items():
        pits = [n[2] for n in mel]
        stats.append(dict(ch=ch, mel=mel, mean=sum(pits) / len(pits),
                          n=len(mel), uniq=len(set(pits)),
                          score=melodic_score(mel)))
    stats.sort(key=lambda s: s["mean"])
    means = [s["mean"] for s in stats]
    med = means[len(means) // 2]

    # bass = lowest-register channel
    bass = stats[0]["mel"]
    used = {stats[0]["ch"]}
    # lead = the most MELODIC line (singable score) at/above median register
    upper = [s for s in stats if s["mean"] >= med and s["ch"] not in used] or \
            [s for s in stats if s["ch"] not in used]
    lead_s = max(upper, key=lambda s: s["score"])
    lead = lead_s["mel"]; used.add(lead_s["ch"])
    rest = [s for s in stats if s["ch"] not in used]
    # harmony = next-best supporting line by activity; counter = next melodic
    harmony = max(rest, key=lambda s: s["n"])["mel"] if rest else []
    if rest:
        used.add(max(rest, key=lambda s: s["n"])["ch"])
    rest2 = [s for s in stats if s["ch"] not in used]
    counter = max(rest2, key=lambda s: s["score"])["mel"] if rest2 else []

    lanes = {0: lead, 1: harmony, 2: bass, 3: [], 4: counter}
    seen = set()
    for (s, p, v) in sorted(parsed["drum_lane"]):
        if (s, p) in seen:
            continue
        seen.add((s, p))
        lanes[3].append((s, 1, p, v))

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
    start = best_mel_window(lanes[0], total_bars)
    allv = [v for ln in lanes.values() for (_, _, _, v) in ln]
    maxv = max(allv) if allv else 0

    def vscale(v):
        return 0.85 if maxv <= 0 else round(0.5 + 0.45 * (v / maxv), 2)

    lead_ph = B._phrase(lanes[0], shift, start, 40, vscale)
    if len(lead_ph) < 6 or not is_real_melody(lead_ph):
        return None                                # reject non-melodic picks
    harmony_ph = B._phrase(lanes[1], shift, start, 32, vscale)
    counter_ph = B._phrase(lanes[4], shift, start, 28, vscale)
    bass_ph = B._phrase(lanes[2], shift, start, 28, vscale)
    drums_ph = B._drum_phrase(lanes[3], start, 64, vscale)

    chords = []
    for b in range(B.WIN):
        lo, hi = (start + b) * SPB, (start + b + 1) * SPB
        pcs = [p % 12 for ln in (2, 1, 0)
               for (s16, d16, p, v) in lanes[ln] if lo <= s16 < hi]
        chords.append(B.degree_of(Counter(pcs).most_common(1)[0][0], root, scale)
                      if pcs else (chords[-1] if chords else 0))

    bpm = int(max(70, min(190, parsed["tempo"] or 125)))
    npb = len(lead_ph) / B.WIN
    arousal = 1 if (npb >= 4 or bpm >= 140) else 0
    valence = 1 if mode == "major" else 0
    quad = {(1, 1): "happy", (0, 1): "tense", (0, 0): "sad",
            (1, 0): "calm"}[(valence, arousal)]

    # MULTIPLE distinct sections from one real contiguous stretch of the track,
    # so the offline composer can lay out a through-composed song (verse /
    # chorus / bridge each with its OWN melody, harmony and bass) instead of
    # looping a single 8-bar idea. Each part is a 4-bar, re-zeroed phrase set.
    region_bars = 16 if total_bars >= 16 else (8 if total_bars >= 8 else 4)
    rstart = best_region(lanes[0], total_bars, region_bars)
    parts = []
    for pb in range(0, region_bars, 4):
        lo = rstart + pb
        lead_p = slice_phrase(lanes[0], shift, lo, 4, 24, vscale)
        nlead = len(lead_p)
        uniq = len({n[1] for n in lead_p})
        part = {
            "lead": lead_p,
            "harmony": slice_phrase(lanes[1], shift, lo, 4, 20, vscale),
            "counter": slice_phrase(lanes[4], shift, lo, 4, 18, vscale),
            "bass": slice_phrase(lanes[2], shift, lo, 4, 18, vscale),
            "drums": slice_phrase(lanes[3], 0, lo, 4, 40, vscale, mono=False),
            "chords": chords_of(lanes, root, scale, lo, 4),
            "energy": round(min(1.0, 0.5 + 0.04 * uniq + 0.008 * nlead), 2),
        }
        parts.append(part)

    return {
        "title": (name or parsed["title"])[:48], "source": source,
        "mood": quad, "valence": valence, "arousal": arousal,
        "scale": mode, "bpm": bpm, "bars": B.WIN,
        "chords": chords, "lead": lead_ph, "harmony": harmony_ph,
        "counter": counter_ph, "bass": bass_ph, "drums": drums_ph,
        "parts": parts,
    }


def structure_of(parsed):
    label, seq = {}, []
    for o in parsed["orders"]:
        if o >= 254 or o >= parsed["patnum"]:
            continue
        label.setdefault(o, chr(ord("A") + (len(label) % 26)))
        seq.append(label[o])
    return "".join(seq[:48]) if len(seq) >= 4 else None


def main():
    exemplars, structures = [], []
    counts = Counter()
    with zipfile.ZipFile(PK3) as z:
        names = sorted(n for n in z.namelist() if n.lower().endswith(".s3m"))
        for n in names:
            data = z.read(n)
            base = os.path.basename(n).replace(".s3m", "")
            try:
                if data[0x2C:0x30] == b"SCRM":
                    parsed = parse_s3m(data); kind = "s3m"
                elif data[:4] == b"IMPM":
                    parsed = parse_it(data); kind = "it"
                else:
                    counts["ogg/other"] += 1; continue
                if parsed is None:
                    counts[kind + " none"] += 1; continue
                e = build_one(base, "ut", parsed)
                if e:
                    exemplars.append(e); counts[kind + " ok"] += 1
                else:
                    counts[kind + " rejected"] += 1
                st = structure_of(parsed)
                if st:
                    structures.append(st)
            except Exception as ex:
                counts["error"] += 1
                print("  fail", base, type(ex).__name__, ex)
    print("counts:", dict(counts))

    by_mood = {}
    for e in exemplars:
        by_mood.setdefault(e["mood"], []).append(e)
    capped = []
    for m, xs in by_mood.items():
        capped.extend(xs[:PER_MOOD])
    json.dump(capped, open(os.path.join(OUT, "ut_exemplars.json"), "w"))
    uniq = list(dict.fromkeys(structures))
    json.dump(uniq, open(os.path.join(OUT, "ut_structures.json"), "w"))
    print("exemplars:", len(capped), "by mood:",
          {m: len(xs[:PER_MOOD]) for m, xs in by_mood.items()})
    print("structures:", len(uniq))
    if capped:
        ex = capped[0]
        print("example:", ex["title"], ex["bpm"], ex["scale"], ex["mood"],
              "lead_uniq=", len(set(n[1] for n in ex["lead"])),
              "chords=", ex["chords"])


if __name__ == "__main__":
    main()
