# Orpheus fine-tuning for ChipMood

Fine-tune the **Orpheus Music Transformer** (Medium, 479M, Apache-2.0) on the
ChipMood MIDI corpus so it composes in a game/chiptune idiom, then render its
notes on the existing Rust 8-bit chip-synth (the sound stays on-device).

Orpheus is a symbolic (notes) model — perfect for us, since we synthesize the
audio ourselves. Token scheme: 3 tokens/note, vocab 18820, seq up to 8192.
See `orpheus_common.py` for the exact codec (mirrors the official Gradio app).

## Pipeline

```
setup_orpheus.py     # download codebase modules + Medium base checkpoint
prepare_data.py      # encode our MIDI corpus -> token windows (train_tokens.pkl)
finetune.py          # fine-tune on a 12 GB GPU (bf16 + 8-bit AdamW), checkpoints
generate.py          # sample a continuation -> .mid + ChipMood song JSON
server_orpheus.py    # serve /compose to the app (drop-in for ml/server.py)
orpheus_common.py    # token codec + model builder/loader
orpheus_to_song.py   # decoded notes -> our 4-voice Song JSON
```

## Run (from the `ml/` directory, using the venv)

```bash
# 0. one-time python deps (model + tokenizer + 8-bit optimizer)
.venv/bin/pip install einops einx bitsandbytes matplotlib scikit-learn

# 1. one-time setup (~2 GB download: code modules + Medium checkpoint)
.venv/bin/python orpheus/setup_orpheus.py

# 2. build the training set from our MIDIs (YM2413 + VGMIDI + POP909 + EMOPIA)
.venv/bin/python orpheus/prepare_data.py

# 3. fine-tune in the background (leave it for hours/days; resumes automatically)
nohup .venv/bin/python orpheus/finetune.py > orpheus/train.log 2>&1 &
tail -f orpheus/train.log

# 4. sample once a checkpoint exists
.venv/bin/python orpheus/generate.py --mood happy --tokens 768 --temp 0.9

# 5. serve to the app (set the app's API URL to this box, offline mode OFF)
.venv/bin/python orpheus/server_orpheus.py
```

## Hardware notes (RTX 3060 12 GB)

`finetune.py` defaults are conservative and fit 12 GB:
`TRAIN_SEQ=1024`, `BATCH=1`, `GRAD_ACCUM=16`, 8-bit AdamW, bf16 autocast.
Expect a good style adaptation in **6–24 h**; comfortable to run ~2 days.
If you OOM, lower `TRAIN_SEQ` to 768/512. If you have headroom, raise `TRAIN_SEQ`
toward 2048 and/or `GRAD_ACCUM`. Checkpoints land in `checkpoints/` (last 3 kept)
and training resumes from the latest one on restart.

## Mood conditioning

Orpheus has no mood tokens, so mood is steered by the **prime seed**: `generate.py`
and the server build a short chord seed using mood-appropriate GM instruments and
intervals (major/lifted for happy/calm, minor/tense otherwise). The fine-tune
teaches the idiom; the seed steers the affect. (A future option is to prime from
a RAG exemplar of the target mood instead of a synthetic chord.)

## Why this fits ChipMood

- Symbolic output → we keep the on-chip Rust synthesis ("the soul").
- Multi-track Orpheus notes reduce cleanly to our lead/harmony/bass/drums voices.
- Same `/compose` JSON schema as the old neural server → zero app changes; just
  point the API URL at `server_orpheus.py` and disable offline mode.
