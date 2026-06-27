"""Objective A/B of two mono WAVs: loudness (RMS dBFS), peak, crest factor
(dynamics) and energy distribution across frequency bands — to see how our chip
render differs tonally from the original and how to calibrate mastering."""
import sys, wave
import numpy as np

BANDS = [("sub", 20, 80), ("bass", 80, 250), ("lowmid", 250, 800),
         ("mid", 800, 2500), ("himid", 2500, 6000), ("treble", 6000, 16000)]


def load(path):
    w = wave.open(path, "rb")
    n = w.getnframes()
    sr = w.getframerate()
    raw = w.readframes(n)
    x = np.frombuffer(raw, dtype=np.int16).astype(np.float64) / 32768.0
    return x, sr


def analyze(path):
    x, sr = load(path)
    rms = np.sqrt(np.mean(x ** 2) + 1e-12)
    peak = np.max(np.abs(x)) + 1e-12
    # spectrum via averaged periodogram
    win = 8192
    hop = win
    mags = np.zeros(win // 2 + 1)
    cnt = 0
    w = np.hanning(win)
    for i in range(0, len(x) - win, hop):
        seg = x[i:i + win] * w
        mags += np.abs(np.fft.rfft(seg)) ** 2
        cnt += 1
    mags /= max(1, cnt)
    freqs = np.fft.rfftfreq(win, 1 / sr)
    total = np.sum(mags) + 1e-12
    band = {}
    for name, lo, hi in BANDS:
        m = (freqs >= lo) & (freqs < hi)
        band[name] = np.sum(mags[m]) / total
    centroid = np.sum(freqs * mags) / total
    return dict(rms=20 * np.log10(rms), peak=20 * np.log10(peak),
                crest=20 * np.log10(peak / rms), centroid=centroid, band=band)


def main():
    a = analyze(sys.argv[1])
    b = analyze(sys.argv[2])
    print(f"{'metric':10} {'ORIGINAL':>12} {'OURS':>12} {'diff':>10}")
    for k in ("rms", "peak", "crest", "centroid"):
        u = "dB" if k != "centroid" else "Hz"
        print(f"{k:10} {a[k]:11.2f}{u[:1]} {b[k]:11.2f}{u[:1]} "
              f"{b[k]-a[k]:9.2f}")
    print("\n band energy share (% of total):")
    print(f"{'band':10} {'ORIGINAL':>12} {'OURS':>12} {'OURS/ORIG':>10}")
    for name, _, _ in BANDS:
        ao, bo = a["band"][name] * 100, b["band"][name] * 100
        ratio = bo / (ao + 1e-9)
        print(f"{name:10} {ao:11.1f}% {bo:11.1f}% {ratio:9.2f}x")


if __name__ == "__main__":
    main()
