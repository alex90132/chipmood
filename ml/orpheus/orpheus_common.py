"""Shared Orpheus helpers: token scheme, MIDI<->token codecs, model builder.

The token vocabulary (PAD_IDX = 18819, vocab size 18820) is:
  [0   .. 255]    delta-time   : time += tok * 16 ms
  [256 .. 16767]  patch+pitch  : (128 * patch) + pitch + 256   (patch 0..128, 128=drums)
  [16768..18815]  dur+velocity : (8 * dur) + octovel + 16768   (dur 1..255, octovel 0..7)
  18816 = SOS, 18817 = OUTRO, 18818 = EOS, 18819 = PAD

Encoding order per chord: delta_time, then for each note [patch_pitch, dur_vel].
This mirrors the official Orpheus Gradio app exactly so weights stay compatible.
"""
import os
import sys

HERE = os.path.dirname(__file__)
CODEBASE = os.path.join(HERE, "codebase")
BASE_DIR = os.path.join(HERE, "base_model")
sys.path.insert(0, CODEBASE)

SEQ_LEN = 8192
PAD_IDX = 18819
SOS, OUTRO, EOS = 18816, 18817, 18818

MEDIUM = {"name": "Orpheus_Music_Transformer_Trained_Model_128497_steps_0.6934_loss_0.7927_acc.pth",
          "depth": 8, "heads": 32}
LARGE = {"name": "Orpheus_Music_Transformer_Large_Trained_Model_43860_steps_0.6682_loss_0.8054_acc.pth",
         "depth": 16, "heads": 16}


# --------------------------------------------------------------------------
# MIDI -> tokens  (replicates Gradio app load_midi, no gradio/audio deps)
# --------------------------------------------------------------------------
def midi_to_tokens(midi_path):
    import TMIDIX
    raw = TMIDIX.midi2single_track_ms_score(midi_path)
    esn = TMIDIX.advanced_score_processor(raw, return_enhanced_score_notes=True,
                                          apply_sustain=True)
    if not (esn and esn[0]):
        return [SOS]
    notes = TMIDIX.augment_enhanced_score_notes(esn[0], sort_drums_last=True)
    notes = TMIDIX.remove_duplicate_pitches_from_escore_notes(notes)
    notes = TMIDIX.fix_escore_notes_durations(notes, min_notes_gap=0)
    dscore = TMIDIX.delta_score_notes(notes)
    dcscore = TMIDIX.chordify_score([d[1:] for d in dscore])

    toks = [SOS]
    for c in dcscore:
        toks.append(c[0][0])  # delta time (already 0..255)
        for e in c:
            dur = max(1, min(255, e[1]))
            pat = max(0, min(128, e[5]))
            ptc = max(1, min(127, e[3]))
            vel = max(8, min(127, e[4]))
            octovel = round(vel / 15) - 1
            toks.append((128 * pat) + ptc + 256)
            toks.append((8 * dur) + octovel + 16768)
    return toks


# --------------------------------------------------------------------------
# tokens -> notes  (replicates save_midi note extraction; ms timing)
# returns list of ['note', time_ms, dur_ms, channel, pitch, vel, patch]
# --------------------------------------------------------------------------
def tokens_to_notes(tokens):
    time = 0
    dur = 1
    vel = 90
    pitch = 60
    channel = 0
    patch = 0
    patches = [-1] * 16
    channels = [0] * 16
    channels[9] = 1
    song = []
    for ss in tokens:
        if 0 <= ss < 256:
            time += ss * 16
        elif 256 <= ss < 16768:
            patch = (ss - 256) // 128
            if patch < 128:
                if patch not in patches:
                    if 0 in channels:
                        cha = channels.index(0)
                        channels[cha] = 1
                    else:
                        cha = 15
                    patches[cha] = patch
                    channel = patches.index(patch)
                else:
                    channel = patches.index(patch)
            if patch == 128:
                channel = 9
            pitch = (ss - 256) % 128
        elif 16768 <= ss < 18816:
            dur = ((ss - 16768) // 8) * 16
            vel = (((ss - 16768) % 8) + 1) * 15
            song.append(['note', time, dur, channel, pitch, vel, patch])
    return song


def write_midi(tokens, out_path_noext):
    """Decode tokens to a .mid file using TMIDIX. Returns the file path."""
    import TMIDIX
    song = tokens_to_notes(tokens)
    if not song:
        return None
    song = TMIDIX.remove_duplicate_pitches_from_escore_notes(song)
    song = TMIDIX.fix_escore_notes_durations(song, min_notes_gap=0)
    out_score, patches, _ = TMIDIX.patch_enhanced_score_notes(song)
    TMIDIX.Tegridy_ms_SONG_to_MIDI_Converter(
        out_score, output_signature='Orpheus', output_file_name=out_path_noext,
        track_name='ChipMood', list_of_MIDI_patches=patches, verbose=False)
    return out_path_noext + '.mid'


# --------------------------------------------------------------------------
# Model
# --------------------------------------------------------------------------
def build_model(depth, heads, seq_len=SEQ_LEN):
    from x_transformer_2_3_1 import TransformerWrapper, AutoregressiveWrapper, Decoder
    model = TransformerWrapper(
        num_tokens=PAD_IDX + 1,
        max_seq_len=seq_len,
        attn_layers=Decoder(dim=2048, depth=depth, heads=heads,
                            rotary_pos_emb=True, attn_flash=True),
    )
    model = AutoregressiveWrapper(model, ignore_index=PAD_IDX, pad_value=PAD_IDX)
    return model


def load_base(spec=MEDIUM, seq_len=SEQ_LEN, map_location='cpu'):
    import torch
    model = build_model(spec["depth"], spec["heads"], seq_len=seq_len)
    ckpt = os.path.join(BASE_DIR, spec["name"])
    model.load_state_dict(torch.load(ckpt, map_location=map_location))
    return model
