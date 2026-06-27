"""Encode the ChipMood MIDI corpus into Orpheus token windows for fine-tuning.

Sources (most on-theme first):
  * YM2413-MDB  — 669 FM video-game tunes (already downloaded & unzipped locally)
  * VGMIDI      — video-game piano arrangements (HF, cached)
  * POP909      — pop songs w/ melody+chords (HF, cached)
  * EMOPIA      — mood-labelled solo piano (local, if present)

Each song -> Orpheus tokens (orpheus_common.midi_to_tokens) -> sliced into
overlapping windows of TRAIN_SEQ length (default 2048, comfortable on 12 GB).
Output: ml/orpheus/data/train_tokens.pkl  (list[list[int]])

Run:  cd ml && .venv/bin/python orpheus/prepare_data.py
"""
import glob
import os
import pickle
import random
import sys

sys.path.insert(0, os.path.dirname(__file__))
import orpheus_common as OC

HERE = os.path.dirname(__file__)
ML = os.path.join(HERE, "..")
OUT = os.path.join(HERE, "data")
os.makedirs(OUT, exist_ok=True)

TRAIN_SEQ = 2048      # window length fed to the model during fine-tuning
STRIDE = 1536         # overlap so phrase boundaries are not always cut the same


def collect_paths(limit_per_source=None):
    paths = []

    # 1) YM2413 (local, cleanest melodic variant)
    ym = os.path.join(ML, "data", "ym2413", "YM2413-MDB-v1.0.2",
                      "midi", "adjust_tempo_remove_delayed_inst")
    if os.path.isdir(ym):
        p = sorted(glob.glob(os.path.join(ym, "*.mid")))
        paths += [("ym", x) for x in (p[:limit_per_source] if limit_per_source else p)]

    # 2) EMOPIA (local)
    emo = os.path.join(ML, "data", "emopia", "EMOPIA_1.0", "midis")
    if os.path.isdir(emo):
        p = sorted(glob.glob(os.path.join(emo, "*.mid")))
        paths += [("emo", x) for x in (p[:limit_per_source] if limit_per_source else p)]

    # 3) VGMIDI + POP909 via HF cache (best-effort; skipped offline)
    try:
        from huggingface_hub import snapshot_download
        vg = snapshot_download("30yu/vgmidi", repo_type="dataset",
                               allow_patterns=["*.mid", "**/*.mid"])
        p = sorted(glob.glob(os.path.join(vg, "**", "*.mid"), recursive=True))
        paths += [("vg", x) for x in (p[:limit_per_source] if limit_per_source else p)]
    except Exception as e:
        print("VGMIDI skipped:", e)
    try:
        from huggingface_hub import snapshot_download
        pop = snapshot_download("c0smic1atte/909_aligned", repo_type="dataset",
                                allow_patterns="POP909-aligned/*.mid")
        p = sorted(glob.glob(os.path.join(pop, "POP909-aligned", "*.mid")))
        paths += [("pop", x) for x in (p[:limit_per_source] if limit_per_source else p)]
    except Exception as e:
        print("POP909 skipped:", e)

    return paths


def windows_from_tokens(toks):
    """Slice a full-song token list into SOS-prefixed training windows."""
    body = toks[1:] if toks and toks[0] == OC.SOS else toks
    if len(body) < 64:
        return []
    out = []
    i = 0
    while i < len(body):
        chunk = body[i:i + TRAIN_SEQ - 2]
        win = [OC.SOS] + chunk
        if i + TRAIN_SEQ - 2 >= len(body):
            win = win + [OC.EOS]
        out.append(win)
        if i + TRAIN_SEQ - 2 >= len(body):
            break
        i += STRIDE
    return out


def main(limit_per_source=None):
    paths = collect_paths(limit_per_source)
    print("Collected", len(paths), "MIDI files")
    by_src = {}
    for s, _ in paths:
        by_src[s] = by_src.get(s, 0) + 1
    print("By source:", by_src)

    all_windows = []
    ok = 0
    for n, (src, p) in enumerate(paths):
        try:
            toks = OC.midi_to_tokens(p)
            wins = windows_from_tokens(toks)
            all_windows.extend(wins)
            if wins:
                ok += 1
        except Exception:
            continue
        if (n + 1) % 100 == 0:
            print(f"  {n + 1}/{len(paths)} songs -> {len(all_windows)} windows", flush=True)

    random.seed(0)
    random.shuffle(all_windows)
    out_path = os.path.join(OUT, "train_tokens.pkl")
    with open(out_path, "wb") as f:
        pickle.dump(all_windows, f)
    print(f"\nUsable songs: {ok}/{len(paths)}")
    print(f"Wrote {len(all_windows)} windows (seq<= {TRAIN_SEQ}) -> {out_path}")


if __name__ == "__main__":
    import sys
    lim = int(sys.argv[1]) if len(sys.argv) > 1 else None
    main(lim)
