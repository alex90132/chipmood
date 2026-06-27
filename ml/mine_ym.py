"""Mine ONLY the YM2413-MDB dataset into assets/rag/ym_exemplars.json.

Run after the 6.4 GB Zenodo archive is unzipped:
    YM2413_DIR=data/ym2413/<extracted-folder> .venv/bin/python mine_ym.py

Always writes the output file (even if empty) so the pubspec asset exists.
"""
import json, os, warnings

import build_extra as E

warnings.filterwarnings("ignore")
OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "rag")


def main():
    ym = E.build_ym2413()
    if ym:
        ym, yc = E.cap_by_mood(ym)
    else:
        yc = {}
    json.dump(ym, open(os.path.join(OUT, "ym_exemplars.json"), "w"))
    print("YM2413 exemplars:", len(ym), yc)


if __name__ == "__main__":
    main()
