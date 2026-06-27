"""Generate a composition with the fine-tuned Orpheus model and decode it.

Loads the latest fine-tuned checkpoint (or the base model if none yet), builds a
prime from a small instrument seed, samples a continuation, then writes both a
.mid file and our ChipMood song JSON (via orpheus_to_song) for the chip synth.

Run:
  cd ml && .venv/bin/python orpheus/generate.py --tokens 768 --temp 0.9 --topp 0.96
"""
import argparse
import glob
import os
import random
import sys

import torch

sys.path.insert(0, os.path.dirname(__file__))
import orpheus_common as OC

HERE = os.path.dirname(__file__)
CKPT_DIR = os.path.join(HERE, "checkpoints")
OUT_DIR = os.path.join(HERE, "out")
os.makedirs(OUT_DIR, exist_ok=True)

# GM patches that read well as chip voices (lead / pad / bass-ish)
SEED_PATCHES = {
    "happy": [80, 81, 38],   # square lead, saw lead, synth bass
    "calm": [89, 88, 33],    # warm pad, new-age pad, finger bass
    "sad": [48, 89, 33],     # strings, pad, bass
    "tense": [81, 30, 38],   # saw lead, dist guitar, synth bass
}


def latest_ckpt():
    cks = glob.glob(os.path.join(CKPT_DIR, "orpheus_chipmood_step*.pt"))
    if not cks:
        return None
    cks.sort(key=lambda p: int(p.split("step")[-1].split(".")[0]))
    return cks[-1]


def build_prime(mood):
    """A minimal SOS + chord seed in the requested mood's instruments."""
    prime = [OC.SOS, 0]
    pats = SEED_PATCHES.get(mood, SEED_PATCHES["happy"])
    base_pitch = {"happy": 60, "calm": 57, "sad": 55, "tense": 59}.get(mood, 60)
    triad = [0, 4, 7] if mood in ("happy", "calm") else [0, 3, 7]
    for i, pat in enumerate(pats):
        ptc = max(1, min(127, base_pitch + triad[i % 3] - (12 if pat in (33, 38) else 0)))
        prime.append((128 * pat) + ptc + 256)
        dur = random.randint(16, 28)
        octovel = random.randint(5, 7)
        prime.append((8 * dur) + octovel + 16768)
    return prime


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mood", default="happy", choices=list(SEED_PATCHES))
    ap.add_argument("--tokens", type=int, default=768)
    ap.add_argument("--temp", type=float, default=0.9)
    ap.add_argument("--topp", type=float, default=0.96)
    args = ap.parse_args()

    from x_transformer_2_3_1 import top_p

    model = OC.load_base(OC.MEDIUM, seq_len=OC.SEQ_LEN, map_location="cpu")
    ck = latest_ckpt()
    if ck:
        print("Loading fine-tuned checkpoint:", ck)
        model.load_state_dict(torch.load(ck, map_location="cpu")["model"])
    else:
        print("No fine-tuned checkpoint yet; using base model.")
    model.to("cuda").eval()

    prime = build_prime(args.mood)
    inp = torch.LongTensor([prime]).cuda()
    ctx = torch.amp.autocast(device_type="cuda", dtype=torch.bfloat16)
    print(f"Generating {args.tokens} tokens (mood={args.mood})...")
    with ctx, torch.no_grad():
        out = model.generate(inp, args.tokens, filter_logits_fn=top_p,
                             filter_kwargs={"thres": args.topp},
                             temperature=args.temp, eos_token=OC.EOS,
                             return_prime=True, verbose=False)
    tokens = out.tolist()[0]

    base = os.path.join(OUT_DIR, f"orpheus_{args.mood}")
    midi = OC.write_midi(tokens, base)
    print("Wrote MIDI:", midi)

    import orpheus_to_song
    song = orpheus_to_song.tokens_to_song(tokens, mood=args.mood)
    import json
    with open(base + ".json", "w") as f:
        json.dump(song, f)
    print("Wrote song JSON:", base + ".json",
          "(%d voices)" % len(song["patterns"][0]["tracks"]))


if __name__ == "__main__":
    main()
