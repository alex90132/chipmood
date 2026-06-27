"""Bootstrap the Orpheus Music Transformer fine-tuning environment.

Downloads the three codebase modules (TMIDIX tokenizer, the x-transformers fork,
and the MIDI->audio helper) plus the *Medium* base checkpoint (479M, the one that
comfortably fine-tunes on a 12 GB RTX 3060) from the official HF repo.

    asigalov61/Orpheus-Music-Transformer   (Apache-2.0)

Everything lands in ml/orpheus/codebase and ml/orpheus/base_model so the rest of
the pipeline can import TMIDIX / x_transformer_2_3_1 and load the weights.

Run:  .venv/bin/python orpheus/setup_orpheus.py
"""
import os
import shutil

from huggingface_hub import hf_hub_download

REPO = "asigalov61/Orpheus-Music-Transformer"
HERE = os.path.dirname(__file__)
CODEBASE = os.path.join(HERE, "codebase")
BASE_DIR = os.path.join(HERE, "base_model")

# The Medium base model — 8 layers / 32 heads, dim 2048, ~479M params.
MEDIUM_CKPT = "Orpheus_Music_Transformer_Trained_Model_128497_steps_0.6934_loss_0.7927_acc.pth"

CODE_FILES = [
    "codebase/TMIDIX.py",
    "codebase/x_transformer_2_3_1.py",
    "codebase/midi_to_colab_audio.py",
]


def fetch(filename, dest_dir):
    os.makedirs(dest_dir, exist_ok=True)
    print("Downloading", filename, "...", flush=True)
    path = hf_hub_download(repo_id=REPO, filename=filename)
    dest = os.path.join(dest_dir, os.path.basename(filename))
    shutil.copy(path, dest)
    print("  ->", dest, "(%.1f MB)" % (os.path.getsize(dest) / 1e6), flush=True)
    return dest


def main():
    for f in CODE_FILES:
        fetch(f, CODEBASE)
    # make codebase a package-importable dir
    open(os.path.join(CODEBASE, "__init__.py"), "w").close()
    fetch(MEDIUM_CKPT, BASE_DIR)
    print("\nSetup complete. Base model + codebase ready.")


if __name__ == "__main__":
    main()
