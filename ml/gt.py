"""Ground-truth: convert a real NES-MDB MIDI through OUR pipeline (tokenizer ->
decode -> song) and write song JSON, to verify the engine sounds musical."""
import glob, json, os, sys
import prepare_data as P
import generate as G

ROOT = os.path.dirname(__file__)
files = sorted(glob.glob(os.path.join(ROOT, "nesmdb_midi/test/*.mid")))
f = files[int(sys.argv[1])] if len(sys.argv) > 1 else files[10]
notes = P.notes_from_midi(f)
# group into our 4 lanes
lane = {"lead": [], "harmony": [], "bass": [], "drums": []}
names = ["lead", "harmony", "bass", "drums"]
maxs = 0
for (s16, d16, inst, p) in notes:
    spb = P.STEPS_PER_BAR
    start = s16 * (4.0 / spb)
    dur = d16 * (4.0 / spb)
    lane[names[inst]].append({"pitch": p, "start": round(start, 3),
                              "duration": round(dur, 3),
                              "velocity": G.VEL[names[inst]]})
    maxs = max(maxs, s16)
bars = maxs // P.STEPS_PER_BAR + 1
song = G.to_song(lane, bars, title="GroundTruth " + os.path.basename(f))
json.dump(song, open(os.path.join(ROOT, "gt_song.json"), "w"))
print("file", os.path.basename(f), "bars", bars,
      {k: len(v) for k, v in lane.items()})
