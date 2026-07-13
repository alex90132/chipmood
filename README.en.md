<h1 align="center">ChipMood</h1>

<p align="center">
  Turns a photo into an original <b>16-bit chiptune</b> — composed and synthesized right on your phone.<br/>
  Point the camera, tap once — the app reads a mood from the colours and writes a whole song. Fully offline.
</p>

<p align="center">
  <a href="README.md">Русский</a> ·
  <b>English</b>
</p>

<p align="center">
  <img alt="License: Unlicense" src="https://img.shields.io/badge/license-Unlicense-blue">
  <img alt="Platform: Android" src="https://img.shields.io/badge/platform-Android-3ddc84">
  <img alt="Runs offline" src="https://img.shields.io/badge/runs-100%25%20offline-f59e0b">
  <img alt="Engine: Rust chip-synth" src="https://img.shields.io/badge/engine-Rust%20chip--synth-b7410e">
</p>

<p align="center">
  <img src="docs/screenshot.webp" width="260" alt="App screen">
  &nbsp;&nbsp;
  <a href="https://github.com/alex90132/chipmood/raw/main/docs/demo.mp4">
    <img src="docs/demo.gif" width="260" alt="Demo">
  </a>
</p>

<p align="center"><sub>screenshot · animated demo (click for the full video with sound)</sub></p>

## What it does

ChipMood is an experiment in on-device, photo-driven music generation. Point the
camera at anything, tap once, and the app reads a mood from the image's colours,
composes a full song from a library of real game-music phrases, and plays it back
on a hand-written chip synthesizer (pulse / triangle / saw / noise). The goal is
a track that sounds like **a human actually wrote and played it**, while keeping
the raw, on-chip "soul" of classic chiptune.

- **Photo → music in one tap** — a light colour analysis (brightness, warmth,
  saturation) sets the mood: happy / tense / sad / calm.
- **Only hits** — each tap generates many candidate tracks; a built-in critic
  scores every one and plays **only the best take** — you never hear the duds.
- **Fully offline** — no cloud, no account, no credits; all sound comes from a
  hand-written Rust synthesizer, not from samples.
- **Remix with any AI chat** — the **Copy** button builds a compact prompt with
  real "hit phrases"; paste the reply back with **Paste** and it's arranged and
  synthesized on-device.
- **Live mixer & export** — mute channels on the fly under the equalizer, export
  a 320 kbps MP3 with the source photo embedded as cover art.

## How it works

1. **Photo → mood.** A `dart:ui` colour analysis maps the shot to a
   valence/arousal quadrant.
2. **Retrieval (RAG).** A library of real, key-normalized building blocks is
   queried by mood — phrases (lead / harmony / counter / bass / drums), chords,
   song forms, grooves, basslines, fills and chord voicings.
3. **Compose (`RagComposer`).** Entirely on-device: it picks coherent material,
   transposes it to a key and lays out a through-composed form (intro →
   developing body → breakdown → lifted final chorus → outro).
   *Optional:* with your own OpenRouter key an LLM writes the plan from the same
   library.
4. **Arrange (`ProceduralArranger` + `MelodyEngine`).** The compact plan becomes
   a dense 8-voice `Composition` with humanized timing and dynamics.
5. **Pick the best take (`HitCritic`).** A symbolic critic scores candidates on
   hook/motif repetition, singable contour, lead-vs-bass consonance, groove
   steadiness, breathing and chorus dynamics — the winner plays.
6. **Synthesize (Rust engine).** Band-limited oscillators (PolyBLEP), drum
   synthesis, a per-voice resonant filter, drive, bitcrush, tremolo and per-note
   tracker effects (arp / slide / vibrato / retrigger / delay).
7. **Master + output.** Glue compressor → leveler → limiter and a small reverb;
   live playback as 16-bit PCM, export to MP3 with cover art.

## Datasets behind the retrieval library

Mined by the scripts in `ml/` into compact JSON in `assets/rag/`:

- **NES-MDB** + General-MIDI (multi-track) — chiptune & broad melodic vocab.
- **POP909** — real pop chord progressions + counter melodies.
- **EMOPIA** — piano clips with precise 4-quadrant valence/arousal labels.
- **VGMIDI** — video-game soundtrack arrangements.
- **YM2413-MDB** — 80s FM video-game music with emotion labels.
- **Unreal / UT99** tracker modules — through-composed forms & demoscene leads
  (our own S3M/IT reader; not redistributed).

## The neural experiment (honest results)

We first tried to **train a neural model** to compose chiptune end-to-end
(`ml/train.py`, `ml/model.py`, `ml/generate.py`, the `ckpt.pt` checkpoint). The
result was **poor** — meandering, structureless output. A competent
symbolic-music model needs far more data, compute and time than we had. So we
pivoted to **retrieval-augmented + rules** — and it sounds dramatically better.
The neural path is still wired in (optional), but not the default.

## Build it yourself

Requirements: Flutter SDK, the Rust toolchain (`rustup`) and the Android NDK. The
Rust crate is built automatically by the `flutter_rust_bridge` hooks.

```bash
flutter pub get
flutter run                      # on a connected device
flutter build apk --release      # release APK
flutter test                                       # Dart tests
cargo test --lib --manifest-path rust/Cargo.toml   # Rust engine tests
```

> Optional LLM composer: paste your own OpenRouter key in **Settings** (none
> ships with the app), or `flutter build apk --dart-define=OPENROUTER_API_KEY=...`.

## Data & copyright

ChipMood's sound comes from a hand-written synthesizer, not from samples. The
retrieval library contains only normalized, transformed note data. Copyrighted
source material (the Unreal/UT99 modules, raw datasets, checkpoints) is **not**
included and is git-ignored — bring your own copies to re-run the miners.

## Acknowledgements

ChipMood stands on a lot of other people's work — thank you:

- **Markov melody model** — the order-2 scale-degree Markov chain is adapted from
  [oscarsandford/chiptune-generation](https://github.com/oscarsandford/chiptune-generation).
- **Mood from music** — the valence/arousal mapping was inspired by
  [serkansulun/midi-emotion](https://github.com/serkansulun/midi-emotion).
- **Orpheus Music Transformer** by Aleksandr Sigalov — the optional fine-tuning
  path under `ml/orpheus/` builds on
  [asigalov61/Orpheus-Music-Transformer](https://huggingface.co/asigalov61/Orpheus-Music-Transformer)
  (Apache-2.0).
- **Datasets**: [NES-MDB](https://github.com/chrisdonahue/nesmdb),
  [POP909](https://github.com/music-x-lab/POP909-Dataset),
  [EMOPIA](https://annahung31.github.io/EMOPIA/),
  [VGMIDI](https://github.com/lucasnfe/vgmidi),
  [YM2413-MDB](https://zenodo.org/records/7520537).
- The **Unreal / UT99** soundtrack is referenced for study only and is not
  redistributed.

## License

Public domain — **The Unlicense** (see [`LICENSE`](LICENSE)). Do whatever you
want with it. Third-party datasets used to generate the bundled data carry their
own terms.
