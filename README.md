# ChipMood

*A research / experimental project · EN / RU*

Turn a photo into an original 16‑bit chiptune track — composed and synthesized
entirely on your device.

<p align="center">
  <img src="docs/screenshot.png" alt="ChipMood app screenshot" width="320">
</p>

<p align="center">
  <a href="https://github.com/alex90132/chipmood/raw/main/docs/demo.mp4">▶ Watch the demo</a>
</p>

---

## EN

### What it is

ChipMood is an experiment in **on‑device, photo‑driven music generation**. Point
the camera at anything, tap once, and the app reads a mood from the image's
colours, composes a full song from a library of real game‑music phrases, and
plays it back on a hand‑written chip synthesizer (pulse / triangle / saw /
noise). It runs **fully offline** by default — no cloud, no account, no credits.

### The goal (and where it stands)

The north star is a track that sounds like **a human actually wrote and played
it** — real structure, a singable melody, tasteful harmony, groove and
dynamics — while keeping the raw, on‑chip "soul" of classic chiptune. This is an
ongoing research project: it gets closer with every iteration, but it is not a
finished product.

### The neural experiment (honest results)

We first tried the obvious thing: **train a neural model** to compose chiptune
end‑to‑end (see `ml/train.py`, `ml/model.py`, `ml/generate.py`, the `ckpt.pt`
checkpoint and the `server.py` inference path). The result was **poor** —
meandering, structureless output that never felt musical. Training a competent
symbolic‑music model needs far more data, compute and time than the project had.

So we pivoted to a **retrieval‑augmented, rules‑driven** approach that leans on
real music instead of a half‑trained model — and it sounds dramatically better.
The neural path is still wired in (optional, behind a settings URL) but is not
the default.

### How it works (pipeline)

1. **Photo → mood.** A small `dart:ui` colour analysis (brightness, warmth,
   saturation) maps the shot to a valence/arousal quadrant: happy / tense /
   sad / calm.
2. **Retrieval (RAG).** A library of real, key‑normalized musical material is
   queried by mood — exemplar phrases (lead / harmony / counter / bass / drums),
   chord progressions, song forms, grooves, basslines, fills and chord voicings.
3. **Compose (`RagComposer`).** Entirely on‑device, it picks coherent material,
   transposes it to a key, lays out a through‑composed form (intro → developing
   body → breakdown → lifted final chorus → outro) and mixes parts from the
   retrieval pool. No network, no AI credits.
   - *Optional LLM path:* with your own OpenRouter API key, an LLM writes the
     song plan instead, guided by the same reference library.
4. **Arrange (`ProceduralArranger` + `MelodyEngine`).** The compact plan becomes
   a dense 8‑voice `Composition`: arpeggiated harmony, walking bass, drum groove
   + fills, per‑section energy curve and humanized timing/velocity.
5. **Synthesize (Rust engine).** A hand‑written engine renders it: band‑limited
   oscillators (PolyBLEP), drum synthesis (kick/snare/hat/tom), per‑voice
   resonant filter, drive, bitcrush, tremolo, per‑note tracker effects (arp /
   slide / vibrato / retrigger / delay) and a tempo‑synced ping‑pong delay.
6. **Master.** A glue compressor → long‑term leveler → brick‑wall limiter bus,
   plus a small reverb, keep levels even and the mix cohesive.
7. **Playback & export.** Audio streams as 16‑bit PCM via `flutter_pcm_sound`
   for live playback; export renders a 320 kbps MP3 with the source photo
   embedded as cover art. A **live mixer** (mute buttons per channel under the
   equalizer) lets you tweak the mix, and the choice carries into the export.

### Datasets behind the retrieval library

Mined by the scripts in `ml/` into compact JSON in `assets/rag/`:

- **NES‑MDB** + a General‑MIDI multi‑track set — chiptune & broad melodic vocab.
- **POP909** — real pop chord progressions + secondary (counter) melodies.
- **EMOPIA** — piano clips with precise 4‑quadrant valence/arousal mood labels.
- **VGMIDI** — video‑game soundtrack arrangements.
- **YM2413‑MDB** — 80s FM video‑game music with emotion labels (mined locally).
- **Unreal / UT99** tracker modules — through‑composed forms & demoscene leads
  (parsed by our own S3M/IT reader; not redistributed).

### Architecture

```
lib/src/
  domain/         entities (Composition, Pattern, Note, Instrument…)
  data/
    composer/     RagComposer — builds the whole song plan offline from RAG
    arranger/     ProceduralArranger + MelodyEngine — plan → dense Composition
    datasources/  OpenRouter (LLM) + Rust synth bridge + PCM player
    knowledge/    NesRag, GrooveLibrary — load the retrieval library
    mappers/      Composition <-> tracker‑style JSON contract
  presentation/   Riverpod providers, controllers, screens, widgets
rust/src/synth/   the synthesis engine (oscillators, drums, FX, mastering)
rust/src/api/     flutter_rust_bridge surface (stream / WAV / MP3)
ml/               offline data‑mining + the (abandoned) neural experiment
assets/rag/       the retrieval library (normalized note data, JSON)
```

### Build & run

Requirements: Flutter SDK, the Rust toolchain (`rustup`) and the Android NDK.
The Rust crate is built automatically by the `flutter_rust_bridge` hooks.

```bash
flutter pub get
flutter run                      # on a connected device
flutter build apk --release      # release APK
flutter test                                       # Dart tests
cargo test --lib --manifest-path rust/Cargo.toml   # Rust engine tests
```

Optional LLM composer: paste your own OpenRouter key in **Settings** (none ships
with the app), or `flutter build apk --dart-define=OPENROUTER_API_KEY=sk-or-...`.

### Data & copyright

ChipMood's sound comes from a hand‑written synthesizer, not from samples. The
retrieval library contains only normalized, transformed note data. Copyrighted
source material (the Unreal/UT99 modules, raw datasets, checkpoints) is **not**
included and is git‑ignored — bring your own copies to re‑run the miners.

### Acknowledgements

ChipMood stands on a lot of other people's work — thank you:

- **Markov melody model** — the order‑2 scale‑degree Markov chain that drives a
  lot of the lead lines is adapted from Oscar Sandford's
  [chiptune-generation](https://github.com/oscarsandford/chiptune-generation).
- **Mood from music** — the continuous valence/arousal mapping was inspired by
  [serkansulun/midi-emotion](https://github.com/serkansulun/midi-emotion).
- **Orpheus Music Transformer** by Aleksandr Sigalov — the optional fine‑tuning
  path under `ml/orpheus/` builds on
  [asigalov61/Orpheus-Music-Transformer](https://huggingface.co/asigalov61/Orpheus-Music-Transformer)
  (Apache‑2.0).
- **Datasets** mined into the retrieval / Markov library:
  [NES‑MDB](https://github.com/chrisdonahue/nesmdb),
  [POP909](https://github.com/music-x-lab/POP909-Dataset),
  [EMOPIA](https://annahung31.github.io/EMOPIA/),
  [VGMIDI](https://github.com/lucasnfe/vgmidi),
  [YM2413‑MDB](https://zenodo.org/records/7520537).
- The **Unreal / UT99** soundtrack is referenced for study only and is not
  redistributed.

Each project keeps its own license; only normalized note data derived from them
ships in this repo.

### License

Public domain — **The Unlicense** (see `LICENSE`). Do whatever you want with it.
Third‑party datasets used to generate the bundled data carry their own terms.

---

## RU

### Что это

ChipMood — это эксперимент по **генерации музыки на устройстве по фотографии**.
Наводишь камеру на что угодно, жмёшь один раз — приложение определяет настроение
по цветам снимка, сочиняет целый трек из библиотеки реальных игровых музыкальных
фраз и проигрывает его на собственном чип‑синтезаторе (импульс / треугольник /
пила / шум). По умолчанию работает **полностью офлайн** — без облака, аккаунта и
кредитов.

### Цель (и где мы сейчас)

Главная цель — чтобы трек звучал так, **будто его написал и сыграл живой
человек**: настоящая структура, поющаяся мелодия, со вкусом гармония, грув и
динамика — при этом сохраняя сырую «чиповую душу» классического chiptune. Это
исследовательский проект «в процессе»: с каждой итерацией ближе к цели, но это
ещё не законченный продукт.

### Нейросетевой эксперимент (честный результат)

Сначала попробовали очевидное — **обучить нейросеть** сочинять chiptune целиком
(см. `ml/train.py`, `ml/model.py`, `ml/generate.py`, чек‑пойнт `ckpt.pt` и
инференс в `server.py`). Результат оказался **очень плачевным**: бессвязный,
бесструктурный вывод, который ни разу не звучал музыкально. Чтобы обучить
вменяемую модель символьной музыки, нужно несравнимо больше данных, вычислений и
времени, чем было у проекта.

Поэтому мы перешли к подходу **retrieval‑augmented + правила**, который опирается
на реальную музыку, а не на недообученную модель — и звучит он несравнимо лучше.
Нейросетевой путь остался в коде (опционально, за URL в настройках), но не по
умолчанию.

### Как это работает (конвейер)

1. **Фото → настроение.** Лёгкий анализ цвета через `dart:ui` (яркость, теплота,
   насыщенность) определяет квадрант valence/arousal: happy / tense / sad / calm.
2. **Поиск (RAG).** Библиотека реальных, нормализованных по тональности
   музыкальных «кирпичиков» запрашивается по настроению — фразы‑образцы (лид /
   гармония / контрапункт / бас / барабаны), прогрессии аккордов, формы песен,
   грувы, бас‑линии, сбивки и аккордовые голосования.
3. **Сочинение (`RagComposer`).** Полностью на устройстве: выбирает связный
   материал, транспонирует в тональность, выстраивает сквозную форму (вступление
   → развитие → брейкдаун → поднятый финальный припев → концовка) и смешивает
   партии из пула. Без сети и ИИ‑кредитов.
   - *Опциональный путь через LLM:* со своим ключом OpenRouter план трека пишет
     модель, опираясь на ту же библиотеку референсов.
4. **Аранжировка (`ProceduralArranger` + `MelodyEngine`).** Компактный план
   превращается в плотную 8‑голосную `Composition`: арпеджированная гармония,
   шагающий бас, грув барабанов + сбивки, энергетическая кривая по секциям и
   «человеческая» агогика/динамика.
5. **Синтез (движок на Rust).** Собственный движок рендерит звук: band‑limited
   осцилляторы (PolyBLEP), синтез барабанов (кик/снейр/хэт/том), резонансный
   фильтр на голос, драйв, бит‑краш, тремоло, по‑нотные трекерные эффекты (арп /
   слайд / вибрато / ретриг / дилей) и темпо‑синхронный ping‑pong дилей.
6. **Мастеринг.** Шина glue‑компрессор → долговременный левелер → брик‑волл
   лимитер плюс небольшой реверб — ровная громкость и связный микс.
7. **Воспроизведение и экспорт.** Звук стримится как 16‑bit PCM через
   `flutter_pcm_sound`; экспорт рендерит MP3 320 kbps с фото‑обложкой внутри
   файла. **Живой микшер** (кнопки мьюта каналов под эквалайзером) позволяет
   править микс, и настройка сохраняется в экспорт.

### Датасеты в основе библиотеки

Намайнены скриптами в `ml/` в компактный JSON в `assets/rag/`:

- **NES‑MDB** + набор General‑MIDI (мульти‑трек) — chiptune и широкая мелодика.
- **POP909** — реальные поп‑прогрессии аккордов + контрапункт.
- **EMOPIA** — фортепианные клипы с точными метками настроения (4 квадранта).
- **VGMIDI** — аранжировки игровых саундтреков.
- **YM2413‑MDB** — FM игровая музыка 80‑х с эмо‑метками (майнится локально).
- Трекерные модули **Unreal / UT99** — сквозные формы и демосцен‑лиды (читаются
  собственным парсером S3M/IT; не распространяются).

### Архитектура

```
lib/src/
  domain/         сущности (Composition, Pattern, Note, Instrument…)
  data/
    composer/     RagComposer — собирает план трека офлайн из RAG
    arranger/     ProceduralArranger + MelodyEngine — план → плотная Composition
    datasources/  OpenRouter (LLM) + мост к Rust‑синту + PCM‑плеер
    knowledge/    NesRag, GrooveLibrary — загрузка библиотеки референсов
    mappers/      Composition <-> трекерный JSON‑контракт
  presentation/   провайдеры Riverpod, контроллеры, экраны, виджеты
rust/src/synth/   движок синтеза (осцилляторы, барабаны, эффекты, мастеринг)
rust/src/api/     поверхность flutter_rust_bridge (stream / WAV / MP3)
ml/               офлайн‑майнинг + (заброшенный) нейросетевой эксперимент
assets/rag/       библиотека референсов (нормализованные ноты, JSON)
```

### Сборка и запуск

Нужны: Flutter SDK, тулчейн Rust (`rustup`) и Android NDK. Rust‑крейт собирается
автоматически хуками `flutter_rust_bridge`.

```bash
flutter pub get
flutter run                      # на подключённом устройстве
flutter build apk --release      # релизный APK
flutter test                                       # Dart‑тесты
cargo test --lib --manifest-path rust/Cargo.toml   # тесты движка
```

LLM‑композитор (опционально): введи свой ключ OpenRouter в **Настройках** (в
приложении ключа нет) или `flutter build apk --dart-define=OPENROUTER_API_KEY=...`.

### Данные и авторские права

Звук ChipMood идёт от собственного синтезатора, а не от сэмплов. Библиотека
референсов содержит только нормализованные, преобразованные ноты. Защищённый
авторским правом исходный материал (модули Unreal/UT99, сырые датасеты,
чек‑пойнты) **не** включён и в `.gitignore` — для перезапуска майнеров принеси
свои копии.

### Благодарности

ChipMood стоит на работе многих людей — спасибо:

- **Марковская модель мелодии** — цепь Маркова 2‑го порядка по ступеням лада,
  на которой строится значительная часть лид‑партий, адаптирована из проекта
  Оскара Сэндфорда
  [chiptune-generation](https://github.com/oscarsandford/chiptune-generation).
- **Настроение из музыки** — непрерывное отображение valence/arousal вдохновлено
  [serkansulun/midi-emotion](https://github.com/serkansulun/midi-emotion).
- **Orpheus Music Transformer** Александра Сигалова — опциональный путь
  дообучения в `ml/orpheus/` построен на
  [asigalov61/Orpheus-Music-Transformer](https://huggingface.co/asigalov61/Orpheus-Music-Transformer)
  (Apache‑2.0).
- **Датасеты**, намайненные в библиотеку референсов / Маркова:
  [NES‑MDB](https://github.com/chrisdonahue/nesmdb),
  [POP909](https://github.com/music-x-lab/POP909-Dataset),
  [EMOPIA](https://annahung31.github.io/EMOPIA/),
  [VGMIDI](https://github.com/lucasnfe/vgmidi),
  [YM2413‑MDB](https://zenodo.org/records/7520537).
- Саундтрек **Unreal / UT99** использован только для изучения и не
  распространяется.

У каждого проекта своя лицензия; в репозиторий попадают только производные
нормализованные ноты.

### Лицензия

Public domain — **The Unlicense** (см. `LICENSE`). Делай с проектом что угодно.
Сторонние датасеты, использованные для генерации данных, имеют свои условия.
