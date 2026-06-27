"""Neural chiptune composer server.

POST /compose  -> Song JSON (instruments/patterns/arrangement) that the Flutter
app feeds straight to the Rust chip-synth. The model only writes notes; the
8-bit sound is still produced on-device.
"""
import os, torch
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

from model import GPT, Config
import generate as gen

app = FastAPI(title="ChipComposer")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"],
                   allow_headers=["*"])

device = "cuda" if torch.cuda.is_available() else "cpu"
_model = None
_meta = None


def model():
    global _model, _meta
    if _model is None:
        _model, _meta = gen.load()
    return _model, _meta


class Req(BaseModel):
    seconds: float = 154.0
    temperature: float = 0.7
    max_new: int = 2600
    top_k: int = 24


@app.get("/health")
def health():
    return {"ok": True, "device": device}


def _sane(song):
    by = {t["instrument"]: len(t["notes"]) for t in song["patterns"][0]["tracks"]}
    lead, bass = by.get("lead", 0), by.get("bass", 0)
    return 8 <= lead <= 700 and bass >= 4


@app.post("/compose")
def compose(r: Req):
    m, meta = model()
    bos = meta["vocab"]["BOS"]
    temp = min(r.temperature, 0.78)  # clamp for coherence regardless of client
    best = None
    for _ in range(4):  # retry for a balanced result (small model is noisy)
        idx = torch.tensor([[bos]], dtype=torch.long, device=device)
        out = m.generate(idx, r.max_new, temperature=temp, top_k=r.top_k)[0].tolist()
        notes, bars = gen.decode(out, meta)
        song = gen.to_song(notes, bars)
        best = song
        if _sane(song):
            break
    return best


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
