"""Extract REAL instrument samples (PCM) from the UT99 tracker modules into a
single packed sample bank the Rust sampler engine loads. S3M samples are raw
PCM; IT samples are raw unless compressed (we skip compressed ones).

For each sample we keep: decoded mono PCM (i16), its native sample rate, loop
points, a category (kick/snare/hat/tom/bass/melodic) from the name + analysis,
and a detected ROOT MIDI note (via autocorrelation) so the engine can pitch it
correctly. We pick the best few per category and pack into assets/samples/ut_bank.bin:

  [u32 meta_len][meta_json utf8][concatenated i16 LE pcm blobs]
"""
import json, os, struct, zipfile
import numpy as np

import build_ut as U

ROOT = os.path.dirname(__file__)
PK3 = os.path.join(ROOT, "..", "U1+UT99 music.pk3")
OUT_DIR = os.path.join(ROOT, "..", "assets", "samples")
os.makedirs(OUT_DIR, exist_ok=True)

MAX_SR = 22050            # downsample anything hotter to save space
MEL_MAX_S = 1.6           # trim melodic/bass tails
DRUM_MAX_S = 0.6
CAPS = {"kick": 6, "snare": 6, "hat": 6, "tom": 5, "bass": 10, "melodic": 28}


def classify(name, pcm, sr, looped):
    dp = U.drum_pitch(name)
    if dp == 36:
        return "kick"
    if dp == 38:
        return "snare"
    if dp == 42:
        return "hat"
    if dp == 40:
        return "tom"
    n = name.lower()
    if "bass" in n or "sub" in n:
        return "bass"
    if dp is not None:
        return "tom"
    # nameless: guess from signal — short & noisy -> drum-ish, long & looped -> melodic
    dur = len(pcm) / sr
    if dur < 0.35 and not looped:
        # crude: zero-crossing rate high -> hat/snare, low -> kick/tom
        zc = np.mean(np.abs(np.diff(np.sign(pcm)))) / 2.0
        if zc > 0.2:
            return "hat"
        return "kick"
    return "melodic"


def detect_root_midi(pcm, sr):
    """Autocorrelation pitch on the loudest 0.3s window -> root MIDI note."""
    if len(pcm) < 256:
        return 60
    # take a stable middle window
    w = pcm[len(pcm) // 4: len(pcm) // 4 + min(len(pcm) // 2, sr // 3)]
    w = w - np.mean(w)
    if np.max(np.abs(w)) < 1e-4:
        return 60
    ac = np.correlate(w, w, mode="full")[len(w) - 1:]
    lo = int(sr / 1000)   # 1000 Hz max
    hi = int(sr / 50)     # 50 Hz min
    hi = min(hi, len(ac) - 1)
    if hi <= lo + 2:
        return 60
    peak = lo + int(np.argmax(ac[lo:hi]))
    if peak <= 0:
        return 60
    freq = sr / peak
    midi = int(round(69 + 12 * np.log2(freq / 440.0)))
    return max(24, min(96, midi))


def decode_s3m(data, name_filter=None):
    out = []
    if data[0x2C:0x30] != b"SCRM":
        return out
    ordnum, insnum = U.u16(data, 0x20), U.u16(data, 0x22)
    signed = U.u16(data, 0x2A) == 1
    p = 0x60 + ordnum
    ins_ptrs = [U.u16(data, p + 2 * i) for i in range(insnum)]
    for ip in ins_ptrs:
        o = ip * 16
        if o + 0x50 > len(data) or data[o] != 1:
            continue
        length = U.u32(data, o + 0x10)
        if length < 256 or length > 1_000_000:
            continue
        loop_beg = U.u32(data, o + 0x14)
        loop_end = U.u32(data, o + 0x18)
        flags = data[o + 0x1F]
        c2 = U.u32(data, o + 0x20) or 8363
        looped = bool(flags & 1)
        is16 = bool(flags & 4)
        dptr = ((data[o + 0x0D] << 16) | U.u16(data, o + 0x0E)) * 16
        name = data[o + 0x30:o + 0x4C].split(b"\0")[0].decode("latin1", "ignore")
        if is16:
            need = dptr + length * 2
            if need > len(data):
                continue
            raw = np.frombuffer(data[dptr:dptr + length * 2], dtype="<i2" if signed
                                else "<u2").astype(np.float64)
            pcm = (raw / 32768.0) if signed else ((raw - 32768.0) / 32768.0)
        else:
            need = dptr + length
            if need > len(data):
                continue
            raw = np.frombuffer(data[dptr:dptr + length],
                                dtype="i1" if signed else "u1").astype(np.float64)
            pcm = (raw / 128.0) if signed else ((raw - 128.0) / 128.0)
        out.append(dict(name=name, pcm=pcm, sr=c2, loop_beg=loop_beg,
                        loop_end=loop_end if looped else 0, looped=looped))
    return out


def decode_it(data):
    out = []
    if data[:4] != b"IMPM":
        return out
    ordnum = U.u16(data, 0x20)
    insnum = U.u16(data, 0x22)
    smpnum = U.u16(data, 0x24)
    p = 0xC0 + ordnum + 4 * insnum
    smp_off = [U.u32(data, p + 4 * i) for i in range(smpnum)]
    for so in smp_off:
        if so == 0 or so + 0x50 > len(data) or data[so:so + 4] != b"IMPS":
            continue
        flags = data[so + 0x12]
        if flags & 0x08:                  # compressed -> skip
            continue
        is16 = bool(flags & 0x02)
        looped = bool(flags & 0x10)
        length = U.u32(data, so + 0x30)
        if length < 256 or length > 1_000_000:
            continue
        loop_beg = U.u32(data, so + 0x34)
        loop_end = U.u32(data, so + 0x38)
        c5 = U.u32(data, so + 0x3C) or 8363
        conv = data[so + 0x2E]
        signed = bool(conv & 0x01)
        dptr = U.u32(data, so + 0x48)
        name = data[so + 0x14:so + 0x2E].split(b"\0")[0].decode("latin1", "ignore")
        stereo = bool(flags & 0x04)
        chans = 2 if stereo else 1
        if is16:
            need = dptr + length * 2 * chans
            if need > len(data):
                continue
            raw = np.frombuffer(data[dptr:dptr + length * 2 * chans],
                                dtype="<i2" if signed else "<u2").astype(np.float64)
            pcm = raw / 32768.0 if signed else (raw - 32768.0) / 32768.0
        else:
            need = dptr + length * chans
            if need > len(data):
                continue
            raw = np.frombuffer(data[dptr:dptr + length * chans],
                                dtype="i1" if signed else "u1").astype(np.float64)
            pcm = raw / 128.0 if signed else (raw - 128.0) / 128.0
        if stereo:
            pcm = pcm[::2]                # take left
        out.append(dict(name=name, pcm=pcm, sr=c5, loop_beg=loop_beg,
                        loop_end=loop_end if looped else 0, looped=looped))
    return out


def resample(pcm, sr, target):
    if sr <= target:
        return pcm, sr
    ratio = target / sr
    n = int(len(pcm) * ratio)
    if n < 16:
        return pcm, sr
    xi = np.linspace(0, len(pcm) - 1, n)
    return np.interp(xi, np.arange(len(pcm)), pcm), target


def main():
    pool = {k: [] for k in CAPS}
    with zipfile.ZipFile(PK3) as z:
        for nm in sorted(n for n in z.namelist() if n.lower().endswith(".s3m")):
            data = z.read(nm)
            try:
                samps = decode_s3m(data) if data[0x2C:0x30] == b"SCRM" else decode_it(data)
            except Exception:
                continue
            for s in samps:
                pcm = s["pcm"]
                if np.max(np.abs(pcm)) < 0.02:
                    continue
                cat = classify(s["name"], pcm, s["sr"], s["looped"])
                # trim
                max_s = DRUM_MAX_S if cat in ("kick", "snare", "hat", "tom") else MEL_MAX_S
                pcm, sr = resample(pcm, s["sr"], MAX_SR)
                # scale loop points to the resampled rate
                f = sr / s["sr"]
                lb = int(s["loop_beg"] * f)
                le = int(s["loop_end"] * f)
                limit = int(max_s * sr)
                if cat in ("kick", "snare", "hat", "tom") or le == 0:
                    pcm = pcm[:limit]
                    if le > len(pcm):
                        le = 0
                # normalize peak
                pk = np.max(np.abs(pcm)) + 1e-9
                pcm = (pcm / pk) * 0.95
                root = 60
                if cat in ("bass", "melodic"):
                    root = detect_root_midi(pcm, sr)
                quality = len(pcm) * (1.2 if s["looped"] else 1.0)
                pool[cat].append(dict(name=s["name"][:24], cat=cat, sr=sr,
                                      pcm=pcm.astype(np.float32), loop_beg=lb,
                                      loop_end=le, root=root, q=quality))

    # pick best per category (prefer looped, decent length, dedupe by name)
    meta, blob = [], bytearray()
    for cat, items in pool.items():
        items.sort(key=lambda s: -s["q"])
        seen, kept = set(), []
        for s in items:
            key = (s["name"], len(s["pcm"]))
            if key in seen:
                continue
            seen.add(key)
            kept.append(s)
            if len(kept) >= CAPS[cat]:
                break
        for i, s in enumerate(kept):
            i16 = np.clip(s["pcm"] * 32767.0, -32768, 32767).astype("<i2").tobytes()
            meta.append(dict(name=f"{cat}{i}", src=s["name"], category=cat,
                             root_midi=s["root"], sample_rate=s["sr"],
                             length=len(s["pcm"]),
                             loop_start=s["loop_beg"],
                             loop_end=min(s["loop_end"], len(s["pcm"])),
                             offset=len(blob)))
            blob += i16

    mj = json.dumps({"version": 1, "samples": meta}).encode("utf-8")
    with open(os.path.join(OUT_DIR, "ut_bank.bin"), "wb") as f:
        f.write(struct.pack("<I", len(mj)))
        f.write(mj)
        f.write(blob)
    by_cat = {}
    for m in meta:
        by_cat[m["category"]] = by_cat.get(m["category"], 0) + 1
    print("samples:", len(meta), by_cat)
    print("bank size: %.2f MB" % ((len(mj) + len(blob)) / 1e6))


if __name__ == "__main__":
    main()
