"""Train the small chiptune GPT on the tokenized NES-MDB."""
import json, os, time, math
import numpy as np
import torch
from model import GPT, Config

ROOT = os.path.dirname(__file__)
DATA = os.path.join(ROOT, "data")
CKPT = os.path.join(ROOT, "ckpt.pt")

device = "cuda" if torch.cuda.is_available() else "cpu"
torch.manual_seed(1337)

meta = json.load(open(os.path.join(DATA, "meta.json")))
vocab_size = len(meta["vocab"])

block_size = 384
batch_size = 48
max_iters = 5000
eval_interval = 250
eval_iters = 50
lr = 3e-4
warmup = 200
min_lr = 3e-5
weight_decay = 0.1

train = np.memmap(os.path.join(DATA, "train.bin"), dtype=np.uint16, mode="r")
val = np.memmap(os.path.join(DATA, "valid.bin"), dtype=np.uint16, mode="r")


def get_batch(split):
    d = train if split == "train" else val
    ix = torch.randint(len(d) - block_size - 1, (batch_size,))
    x = torch.stack([torch.from_numpy(d[i:i + block_size].astype(np.int64)) for i in ix])
    y = torch.stack([torch.from_numpy(d[i + 1:i + 1 + block_size].astype(np.int64)) for i in ix])
    return x.to(device), y.to(device)


def lr_at(it):
    if it < warmup:
        return lr * it / warmup
    if it > max_iters:
        return min_lr
    r = (it - warmup) / (max_iters - warmup)
    return min_lr + 0.5 * (1 + math.cos(math.pi * r)) * (lr - min_lr)


cfg = Config(vocab_size=vocab_size, block_size=block_size, n_layer=8,
             n_head=6, n_embd=384, dropout=0.1)
model = GPT(cfg).to(device)
print("params(M):", sum(p.numel() for p in model.parameters()) / 1e6)

opt = torch.optim.AdamW(model.parameters(), lr=lr, weight_decay=weight_decay,
                        betas=(0.9, 0.95))
scaler = torch.amp.GradScaler("cuda", enabled=(device == "cuda"))


@torch.no_grad()
def estimate():
    model.eval()
    out = {}
    for sp in ["train", "val"]:
        losses = torch.zeros(eval_iters)
        for k in range(eval_iters):
            x, y = get_batch(sp)
            with torch.amp.autocast("cuda", dtype=torch.bfloat16, enabled=(device == "cuda")):
                _, loss = model(x, y)
            losses[k] = loss.item()
        out[sp] = losses.mean().item()
    model.train()
    return out


best = 1e9
t0 = time.time()
for it in range(max_iters + 1):
    for g in opt.param_groups:
        g["lr"] = lr_at(it)
    if it % eval_interval == 0:
        e = estimate()
        dt = time.time() - t0
        print(f"iter {it}: train {e['train']:.3f} val {e['val']:.3f} lr {lr_at(it):.2e} {dt:.0f}s", flush=True)
        if e["val"] < best:
            best = e["val"]
            torch.save({"model": model.state_dict(), "cfg": cfg.__dict__,
                        "meta": meta, "val": best}, CKPT)
    if it == max_iters:
        break
    x, y = get_batch("train")
    with torch.amp.autocast("cuda", dtype=torch.bfloat16, enabled=(device == "cuda")):
        _, loss = model(x, y)
    opt.zero_grad(set_to_none=True)
    scaler.scale(loss).backward()
    scaler.unscale_(opt)
    torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
    scaler.step(opt)
    scaler.update()

print("done. best val:", best, "ckpt:", CKPT)
