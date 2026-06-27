"""FastAPI server that serves the fine-tuned Orpheus model to the ChipMood app.

Drop-in replacement for ml/server.py: exposes POST /compose returning the same
Song JSON schema, so RemoteComposerDataSource.composeSong works unchanged. Point
the app's API base URL at this server (Settings) and turn OFF offline mode to use
the neural path; the 8-bit sound is still rendered on-device by the Rust engine.

Run:  cd ml && .venv/bin/python orpheus/server_orpheus.py
"""
import glob
import os
import sys

import torch
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

sys.path.insert(0, os.path.dirname(__file__))
import orpheus_common as OC
import orpheus_to_song
from generate import build_prime  # reuse the mood-aware prime builder

CKPT_DIR = os.path.join(os.path.dirname(__file__), "checkpoints")

app = FastAPI(title="OrpheusChipComposer")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"],
                   allow_headers=["*"])

device = "cuda" if torch.cuda.is_available() else "cpu"
_model = None


def _latest():
    cks = glob.glob(os.path.join(CKPT_DIR, "orpheus_chipmood_step*.pt"))
    if not cks:
        return None
    cks.sort(key=lambda p: int(p.split("step")[-1].split(".")[0]))
    return cks[-1]


def model():
    global _model
    if _model is None:
        m = OC.load_base(OC.MEDIUM, seq_len=OC.SEQ_LEN, map_location="cpu")
        ck = _latest()
        if ck:
            print("Loading fine-tuned:", ck)
            m.load_state_dict(torch.load(ck, map_location="cpu")["model"])
        else:
            print("No fine-tuned checkpoint; using base model.")
        _model = m.to(device).eval()
    return _model


class Req(BaseModel):
    seconds: float = 154.0
    temperature: float = 0.9
    max_new: int = 768
    top_p: float = 0.96
    mood: str = "happy"


@app.get("/health")
def health():
    return {"ok": True, "device": device, "checkpoint": _latest()}


@app.post("/compose")
def compose(r: Req):
    from x_transformer_2_3_1 import top_p
    m = model()
    prime = build_prime(r.mood)
    inp = torch.LongTensor([prime]).to(device)
    ctx = torch.amp.autocast(device_type="cuda", dtype=torch.bfloat16) if device == "cuda" \
        else torch.amp.autocast(device_type="cpu", dtype=torch.bfloat16)
    with ctx, torch.no_grad():
        out = m.generate(inp, r.max_new, filter_logits_fn=top_p,
                         filter_kwargs={"thres": r.top_p},
                         temperature=min(r.temperature, 0.95), eos_token=OC.EOS,
                         return_prime=True, verbose=False)
    tokens = out.tolist()[0]
    return orpheus_to_song.tokens_to_song(tokens, mood=r.mood)


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
