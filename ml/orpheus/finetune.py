"""Fine-tune the Orpheus Medium base model on the ChipMood corpus.

Tuned for a single 12 GB RTX 3060:
  * fp32 master weights + bf16 autocast forward (Ampere-friendly)
  * 8-bit AdamW (bitsandbytes) to keep optimizer state small
  * dynamic padding per batch, gradient accumulation
  * periodic checkpoints to ml/orpheus/checkpoints/

Designed to be left running for hours/days. Resumes from the latest checkpoint
automatically if one exists.

Run (background):
  cd ml && nohup .venv/bin/python orpheus/finetune.py > orpheus/train.log 2>&1 &
"""
import glob
import math
import os
import pickle
import random
import sys
import time

import torch

sys.path.insert(0, os.path.dirname(__file__))
import orpheus_common as OC

HERE = os.path.dirname(__file__)
DATA = os.path.join(HERE, "data", "train_tokens.pkl")
CKPT_DIR = os.path.join(HERE, "checkpoints")
os.makedirs(CKPT_DIR, exist_ok=True)

# ---- hyperparameters (safe defaults for 12 GB) -------------------------
TRAIN_SEQ = 1536          # truncate windows to this length for training
BATCH = 1                 # micro-batch
GRAD_ACCUM = 16           # effective batch = BATCH * GRAD_ACCUM
LR = 1e-4
WARMUP = 200
MAX_STEPS = 60000         # ~1-2 days on a 3060; stop anytime (checkpoints saved)
SAVE_EVERY = 1000
LOG_EVERY = 20
DEVICE = "cuda"
DTYPE = torch.bfloat16


def load_windows():
    with open(DATA, "rb") as f:
        wins = pickle.load(f)
    wins = [w[:TRAIN_SEQ] for w in wins if len(w) >= 32]
    print(f"Loaded {len(wins)} training windows (<= {TRAIN_SEQ} tokens)")
    return wins


def make_batch(wins):
    batch = [random.choice(wins) for _ in range(BATCH)]
    maxlen = max(len(b) for b in batch)
    x = torch.full((BATCH, maxlen), OC.PAD_IDX, dtype=torch.long)
    for i, b in enumerate(batch):
        x[i, :len(b)] = torch.tensor(b, dtype=torch.long)
    return x


def latest_ckpt():
    cks = glob.glob(os.path.join(CKPT_DIR, "orpheus_chipmood_step*.pt"))
    if not cks:
        return None
    cks.sort(key=lambda p: int(p.split("step")[-1].split(".")[0]))
    return cks[-1]


def main():
    assert os.path.exists(DATA), "Run orpheus/prepare_data.py first."
    wins = load_windows()

    print("Building Medium model + loading base weights...", flush=True)
    model = OC.load_base(OC.MEDIUM, seq_len=OC.SEQ_LEN, map_location="cpu")
    model.to(DEVICE)
    model.train()

    start_step = 0
    ck = latest_ckpt()
    if ck:
        print("Resuming from", ck, flush=True)
        sd = torch.load(ck, map_location="cpu")
        model.load_state_dict(sd["model"])
        start_step = sd.get("step", 0)

    try:
        import bitsandbytes as bnb
        opt = bnb.optim.AdamW8bit(model.parameters(), lr=LR, betas=(0.9, 0.95))
        print("Using bitsandbytes 8-bit AdamW")
    except Exception as e:
        print("bitsandbytes unavailable (%s); falling back to AdamW" % e)
        opt = torch.optim.AdamW(model.parameters(), lr=LR, betas=(0.9, 0.95))

    def lr_at(step):
        if step < WARMUP:
            return LR * step / max(1, WARMUP)
        prog = (step - WARMUP) / max(1, MAX_STEPS - WARMUP)
        return LR * 0.1 + 0.9 * LR * 0.5 * (1 + math.cos(math.pi * min(1.0, prog)))

    ctx = torch.amp.autocast(device_type="cuda", dtype=DTYPE)
    t0 = time.time()
    running = 0.0
    opt.zero_grad(set_to_none=True)

    for step in range(start_step, MAX_STEPS):
        for g in opt.param_groups:
            g["lr"] = lr_at(step)

        for _ in range(GRAD_ACCUM):
            x = make_batch(wins).to(DEVICE)
            with ctx:
                loss = model(x)
                if isinstance(loss, (tuple, list)):
                    loss = loss[0]
            (loss / GRAD_ACCUM).backward()
            running += loss.item() / GRAD_ACCUM

        torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
        opt.step()
        opt.zero_grad(set_to_none=True)

        if (step + 1) % LOG_EVERY == 0:
            avg = running / LOG_EVERY
            running = 0.0
            dt = time.time() - t0
            t0 = time.time()
            print(f"step {step+1}/{MAX_STEPS}  loss {avg:.4f}  lr {lr_at(step):.2e}  "
                  f"{LOG_EVERY*GRAD_ACCUM/dt:.1f} seq/s", flush=True)

        if (step + 1) % SAVE_EVERY == 0:
            path = os.path.join(CKPT_DIR, f"orpheus_chipmood_step{step+1}.pt")
            torch.save({"model": model.state_dict(), "step": step + 1}, path)
            print("Saved", path, flush=True)
            # keep only the 3 most recent checkpoints to save disk
            cks = sorted(glob.glob(os.path.join(CKPT_DIR, "orpheus_chipmood_step*.pt")),
                         key=lambda p: int(p.split("step")[-1].split(".")[0]))
            for old in cks[:-3]:
                os.remove(old)

    print("Training complete.")


if __name__ == "__main__":
    main()
