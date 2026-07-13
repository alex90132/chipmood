import '../../domain/entities/composition.dart';
import '../../domain/entities/envelope.dart';
import '../../domain/entities/instrument.dart';
import '../../domain/entities/note.dart';
import '../../domain/entities/pattern.dart';
import '../../domain/entities/waveform.dart';
import '../knowledge/groove_library.dart';
import '../knowledge/markov_library.dart';
import 'melody_engine.dart';

/// Turns the AI's compact "song plan" (key + chords-per-section + lead melody)
/// into a DENSE, musical [Composition]: the AI provides the creative skeleton,
/// this arranger performs it — arpeggiated harmony, a moving bass and a drum
/// groove with fills — so even a small/fast model yields a rich track.
class ProceduralArranger {
  const ProceduralArranger();

  static const _scales = <String, List<int>>{
    'major': [0, 2, 4, 5, 7, 9, 11],
    'minor': [0, 2, 3, 5, 7, 8, 10],
    'harmonicminor': [0, 2, 3, 5, 7, 8, 11],
    'dorian': [0, 2, 3, 5, 7, 9, 10],
    'mixolydian': [0, 2, 4, 5, 7, 9, 10],
    'phrygian': [0, 1, 3, 5, 7, 8, 10],
  };

  Composition build(Map<String, dynamic> spec,
      {double targetSeconds = 154,
      GrooveData? grooves,
      MarkovModel? markov,
      String? sampleBank}) {
    final bpm = _d(spec['bpm'], 132).clamp(60, 220).toDouble();
    // Models sometimes give the tonic as a pitch-class/degree (e.g. 0) instead
    // of a MIDI note. Normalize into a musical octave so bass/harmony sit right.
    var root = _i(spec['root'], 60);
    while (root < 54) {
      root += 12;
    }
    while (root > 66) {
      root -= 12;
    }
    final scale = _scales[(spec['scale'] as String?)?.toLowerCase().trim()] ??
        _scales['minor']!;

    final sectionsJson = (spec['sections'] as List?) ?? const [];
    final engine = MelodyEngine(scale: scale, register: root + 12);
    // Seed from the WHOLE plan (title, key, tempo, structure, chords) — not just
    // the title — so two generations differ (different groove/bassline/timbre)
    // even from a similar photo, yet the same plan always reproduces (copy/paste).
    var songSeed = _seedFrom(spec['title'], root, scale);
    songSeed = (songSeed * 1000003 + bpm.round()) & 0x7FFFFFFF;
    songSeed = (songSeed * 1000003 + sectionsJson.length) & 0x7FFFFFFF;
    for (final sec in sectionsJson.whereType<Map<String, dynamic>>()) {
      for (final c in (sec['chords'] as List?) ?? const []) {
        songSeed = (songSeed * 31 + _i(c, 0)) & 0x7FFFFFFF;
      }
    }
    // A true per-generation random seed from the composer (stored in the plan,
    // so pasting the same plan still reproduces). Without it the seed came
    // only from a tiny title pool + root + chords and collided often — many
    // "different" tracks landed on the SAME style/groove/timbres.
    final specSeed = _i(spec['seed'], 0);
    if (specSeed != 0) {
      songSeed = (songSeed ^ (specSeed * 0x9E3779B1)) & 0x7FFFFFFF;
    }
    if (songSeed == 0) songSeed = 0x1234567;
    final hook = engine.makeHook(songSeed);
    final style = _Style.pick(songSeed);
    final timbre = _str(spec['timbre'], '').toLowerCase();
    final prod = _Production.parse(spec['production']);
    // Independent, well-mixed pick stream: the old `songSeed % n` /
    // `(songSeed ~/ k) % n` picks were heavily correlated (nearby seeds chose
    // nearly the same groove/bassline/profile), another reason tracks blurred
    // together. One xorshift stream decorrelates every pick.
    final pick = _Rng(songSeed ^ 0x3C6EF35F);
    // RAG production preset for THIS track (effect amounts from a real song).
    final profileMap = (grooves != null && grooves.profiles.isNotEmpty)
        ? grooves.profiles[pick.range(grooves.profiles.length)]
        : const <String, dynamic>{};
    final profileProd = _Production.parse(profileMap);
    // Per-song FX randomness. NOTE: most mined profiles saturated at the same
    // clamped values (leadDrive 0.7 / cutoff 0.5 / resonance 0.8 ... in ~90%
    // of them), so treating the profile as gospel made nearly every track
    // sound identical. Profiles are now a *tendency* that gets blended with
    // this song's seeded style plus jitter — every track lands elsewhere.
    final fxRng = _Rng(songSeed ^ 0x7ED55D16);
    // Master echo OFF by default — dry chip sound. Only an explicit AI
    // production.delay turns it on (RAG profiles used to smear every track).
    final delayWet = (prod.delay ?? 0.0).clamp(0.0, 0.6).toDouble();
    // Per-note tracker effect usage: RAG profile sets the tendency, the song
    // seed spreads it so no two tracks use the same amounts.
    double pf(String k, double d) => (profileMap[k] as num?)?.toDouble() ?? d;
    double vary(double v) => (v * (0.5 + fxRng.d())).clamp(0.0, 1.0);
    final fxVib = vary(pf('vibAmt', 0.3));
    final fxSlide = vary(pf('slideAmt', 0.15));
    final fxRetrig = vary(pf('retrigAmt', 0.15));
    // Chip (tracker) arpeggio: the mined arpAmt is ~0.7 nearly everywhere, so
    // ">= 0.5" turned it ON for almost every track. Use it as a probability.
    final chipArp = profileMap.isNotEmpty
        ? fxRng.chance((pf('arpAmt', 0.4) * 0.75).clamp(0.0, 0.8))
        : style.chipArp;
    // One real chord voicing for this song's pad (data-driven harmony shape).
    final voicing = (grooves != null && grooves.voicings.isNotEmpty)
        ? grooves.voicings[pick.range(grooves.voicings.length)]
        : null;
    // A real drum groove + bassline for THIS track, so the rhythm and the drum
    // sound come from genuine music (varies completely track to track).
    final beat = (grooves != null && grooves.grooves.isNotEmpty)
        ? grooves.grooves[pick.range(grooves.grooves.length)]
        : null;
    final bassline = (grooves != null && grooves.basslines.isNotEmpty)
        ? grooves.basslines[pick.range(grooves.basslines.length)]
        : null;
    final harmPat = (grooves != null && grooves.harmonies.isNotEmpty)
        ? grooves.harmonies[pick.range(grooves.harmonies.length)]
        : null;
    final arpPat = (grooves != null && grooves.arps.isNotEmpty)
        ? grooves.arps[pick.range(grooves.arps.length)]
        : null;
    // A real RAG lead phrase for THIS track — used to build the melody when an
    // exemplar/AI lead is missing, so even fallbacks are genuine music (RAG is
    // the main source of inspiration), never a purely synthetic line.
    final melPat = (grooves != null && grooves.melodies.isNotEmpty)
        ? grooves.melodies[pick.range(grooves.melodies.length)]
        : null;
    // Generate the LEAD with the Markov melody model (new, in-style melody) for
    // a portion of tracks — set by the composer via spec['markovLead'].
    final markovLead =
        markov != null && markov.ready && spec['markovLead'] == true;

    final patterns = <Pattern>[];
    final ids = <String>{};
    var idx = 0;
    for (final s in sectionsJson.whereType<Map<String, dynamic>>()) {
      final pat = _buildSection(s, root, scale, engine, hook, style,
          songSeed ^ (idx * 0x2545F49), grooves, voicing, beat, bassline,
          harmPat, arpPat, melPat, chipArp, fxVib, fxSlide, fxRetrig,
          markovLead ? markov : null);
      idx++;
      if (pat != null && ids.add(pat.id)) patterns.add(pat);
    }

    var arrangement = ((spec['arrangement'] as List?) ?? const [])
        .map((e) => e.toString())
        .where(ids.contains)
        .toList();
    if (arrangement.isEmpty) arrangement = patterns.map((p) => p.id).toList();

    return Composition(
      title: _str(spec['title'], 'Untitled'),
      bpm: bpm,
      masterVolume: 0.8,
      delayWet: delayWet,
      targetSeconds: targetSeconds,
      sampleBank: sampleBank,
      instruments: style.instruments(
          timbre: timbre,
          beatTone: beat?.tone,
          prod: prod,
          profile: profileProd,
          rng: _Rng(songSeed ^ 0x165667B1),
          sampleOf: _sampleSelector(sampleBank, songSeed)),
      patterns: patterns,
      arrangement: arrangement,
    );
  }

  /// When a sample bank is available, pick a real UT instrument sample per
  /// voice, varied by the song seed so each track draws different timbres.
  /// "@kit" tells the engine to choose a drum sample per note. Returns null
  /// when no bank, so the engine keeps the chip oscillators.
  String? Function(String)? _sampleSelector(String? bank, int seed) {
    if (bank == null) return null;
    const mel = 28; // melodic samples available in the bank
    const bass = 10;
    // Decorrelated per-voice picks (seed%n and seed~/5%n moved almost in
    // lockstep between nearby seeds), and a per-song drum KIT variant instead
    // of every track playing the very first kick/snare/hat sample.
    final r = _Rng(seed ^ 0x27D4EB2F);
    final leadSmp = r.range(mel);
    final counterSmp = r.range(mel);
    final harmonySmp = r.range(mel);
    final arpSmp = r.range(mel);
    final padSmp = r.range(mel);
    final bassSmp = r.range(bass);
    final kit = r.range(6);
    return (id) {
      switch (id) {
        case 'lead':
          return 'melodic$leadSmp';
        case 'counter':
          return 'melodic$counterSmp';
        case 'harmony':
          return 'melodic$harmonySmp';
        case 'arp':
          return 'melodic$arpSmp';
        case 'pad':
          return 'melodic$padSmp';
        case 'bass':
          return 'bass$bassSmp';
        case 'drums':
        case 'perc':
          return '@kit$kit';
      }
      return null;
    };
  }

  Pattern? _buildSection(
      Map<String, dynamic> s,
      int root,
      List<int> scale,
      MelodyEngine engine,
      List<int> hook,
      _Style style,
      int seed,
      GrooveData? grooves,
      List<int>? voicing,
      GrooveBeat? beat,
      List<List<double>>? bassline,
      List<List<double>>? harmPat,
      List<List<double>>? arpPat,
      List<List<double>>? melPat,
      bool chipArp,
      double fxVib,
      double fxSlide,
      double fxRetrig,
      MarkovModel? markov) {
    final id = _str(s['id'], '');
    if (id.isEmpty) return null;
    final bars = _i(s['bars'], 4).clamp(1, 8);
    final energy = _d(s['energy'], 0.8).clamp(0.2, 1.0).toDouble();
    final chords = ((s['chords'] as List?) ?? const [])
        .map((e) => _i(e, 0))
        .toList();
    final transpose = id.toLowerCase().contains('final') ? 2 : 0;
    final isChorus = id.toLowerCase().contains('chorus');
    final isBreak = id.toLowerCase().contains('break');

    final degsPerBar = List<int>.generate(
      bars,
      (b) => chords.isEmpty ? 0 : chords[b % chords.length],
    );

    // Prefer the AI's own voices (RAG-informed); fall back to the per-song
    // varied procedural generators only when a voice is missing/too sparse.
    var harmony = _aiVoice(s['harmony'], scale, root, 4);
    var bass = _aiVoice(s['bass'], scale, root, 3);
    // Drums: if the plan carries a GM-style kit lane (kick 36 / snare 38 /
    // hat 42 ...), KEEP it — the author locked it to their bass, and swapping
    // in a random RAG groove was pulling pasted AI songs apart rhythmically.
    // Only fall back to the real RAG groove (or procedural) when the plan has
    // no usable kit lane.
    var drums = _aiKitDrums(s['drums']);
    final authoredDrums = drums != null;
    drums ??= beat != null ? null : _aiDrums(s['drums'], 3);
    // Lead priority: Markov‑generated original melody (when requested) → the
    // exemplar/AI melody (RAG) → a real RAG lead phrase → procedural engine.
    List<Note>? leadOpt;
    if (markov != null && !isBreak) {
      leadOpt = _markovLead(markov, degsPerBar, scale, root, bars,
          seed ^ 0x6D2B79F5, 0.76 + 0.24 * energy);
    }
    final aiLead = leadOpt == null ? _aiVoice(s['lead'], scale, root, 5) : null;
    final authoredLead = aiLead != null;
    leadOpt ??= aiLead;
    if (leadOpt == null && melPat != null) {
      final ml = <Note>[];
      for (var b = 0; b < bars; b++) {
        _contourBar(ml, b * 4.0, root + 12, degsPerBar[b], scale, melPat,
            0.76 + 0.24 * energy);
      }
      leadOpt = _toMono(ml, 4);
    }
    var lead = leadOpt ??
        engine.generate(
          chordDegsPerBar: degsPerBar,
          bars: bars,
          energy: energy,
          seed: seed,
          isChorus: isChorus,
          hook: hook,
        );

    // Compress how energy maps to loudness so sections don't lurch quiet/loud
    // (the engine's leveler then keeps the overall level steady). Note density
    // still varies with the style, so dynamics read as arrangement, not volume.
    final velEnergy = 0.76 + 0.24 * energy;

    // PER-BAR COVERAGE (no провалы): the backbone (bass + drums) must sound in
    // EVERY bar, and harmony in almost every bar. Whatever the AI gives, any
    // empty bar is filled — drums from the real groove, bass from the real
    // bassline (transposed) — so the track never drops out yet stays unique.
    bass = _fillBars(bass, bars, (out, b) => bassline != null
        ? _contourBar(out, b * 4.0, root - 24, degsPerBar[b], scale, bassline, velEnergy)
        : _bassBar(out, b * 4.0, root - 24, degsPerBar[b], scale, velEnergy, style));
    // Anchor the bass low so it carries real low-end weight: if the average
    // pitch sits too high, drop it an octave (or two) into ~E1-C3.
    bass = _anchorBass(bass);
    drums = _fillBars(drums, bars, (out, b) => beat != null
        ? _grooveBar(out, b * 4.0, beat, velEnergy)
        : _drumBar(out, b * 4.0, velEnergy, b == bars - 1, style));
    harmony = _fillBars(harmony, bars, (out, b) => harmPat != null
        ? _contourBar(out, b * 4.0, root, degsPerBar[b], scale, harmPat, velEnergy)
        : _harmonyBar(out, b * 4.0, root, degsPerBar[b], scale, velEnergy, style));

    // Extra 16-bit layers fill out the texture; they still enter with energy so
    // sections breathe, but generously (RAG material should be heard, not
    // stripped) — the backbone always plays.
    // How much explicit, authored material this section already carries
    // (AI/exemplar lead+harmony+counter+bass). A fully-voiced section is a
    // finished arrangement — piling every procedural layer on top of it is
    // what turned pasted AI songs into mush, so the busier the plan, the
    // higher the bar for adding arp/perc.
    final authored = [s['lead'], s['harmony'], s['counter'], s['bass']]
        .where((v) => v is List && v.length >= 3)
        .length;
    final texGate = authored >= 4 ? 0.25 : (authored == 3 ? 0.12 : 0.0);
    final pad = <Note>[];
    final arp = <Note>[];
    final perc = <Note>[];
    for (var b = 0; b < bars; b++) {
      final barStart = b * 4.0;
      if (energy >= 0.4) {
        _padBar(pad, barStart, root, degsPerBar[b], scale, velEnergy, voicing);
      }
      if (energy >= 0.58 + texGate) {
        if (chipArp) {
          _chipArpBar(arp, barStart, root + 12, degsPerBar[b], scale, velEnergy);
        } else if (arpPat != null) {
          _contourBar(arp, barStart, root + 12, degsPerBar[b], scale, arpPat,
              velEnergy * 0.85);
        } else {
          _arpBar(arp, barStart, root + 12, degsPerBar[b], scale, velEnergy, style);
        }
      }
      if (energy >= 0.52 + texGate) {
        _percBar(perc, barStart, velEnergy, style);
      }
    }

    // Real drum FILL (сбивка) on the section's last bar — a genuine phrase-end
    // run mined from real chiptunes, instead of a generic procedural roll.
    // Skipped for an authored kit lane: its writer already placed the fill,
    // and stacking a second one smears the phrase ending.
    if (!authoredDrums &&
        grooves != null && grooves.fills.isNotEmpty && bars >= 1) {
      final fill = grooves.fills[(seed & 0x7FFFFFFF) % grooves.fills.length];
      final base = (bars - 1) * 4.0;
      for (final n in fill) {
        if (n.length < 4) continue;
        drums.add(Note(
          pitch: n[1].round(),
          start: base + n[0],
          duration: n[2],
          velocity: (n[3] * velEnergy).clamp(0.0, 1.0),
        ));
      }
      // On big sections add a rising TOM/SNARE BUILD over the last beat — a
      // genuine "here comes the drop" sbivka into the next section. Its length
      // and intensity track the section's energy so choruses land hard.
      if (energy >= 0.78) {
        final hits = energy >= 0.92 ? 8 : 6;     // 16ths over the last 1-2 beats
        final step = 0.25;
        final fillStart = base + 4.0 - hits * step;
        for (var i = 0; i < hits; i++) {
          final t = fillStart + i * step;
          final ramp = 0.55 + 0.45 * (i / (hits - 1)); // crescendo
          // a snare roll with tom accents every other hit (40/41 = tom, 38 =
          // snare per the engine's drum mapping) — climbs in intensity.
          final pitch = i.isOdd ? 40 : 38;
          drums.add(Note(
            pitch: pitch,
            start: t,
            duration: step * 0.9,
            velocity: (ramp * velEnergy).clamp(0.0, 1.0),
          ));
        }
      }
      drums.sort((a, b) => a.start.compareTo(b.start));
    }

    // TRANSITION: a rising diatonic pickup run in the last beat of energetic
    // sections, climbing to set up whatever comes next — a real "lead-in" that
    // gives the track forward motion between sections (stays in key/chord).
    // Never on an authored melody: deleting its phrase ending to inject a
    // generic run is exactly the "random notes" effect we're avoiding.
    if (!authoredLead && !isBreak && !isChorus && energy >= 0.65 && bars >= 1) {
      final lastDeg = degsPerBar[bars - 1];
      final base = (bars - 1) * 4.0 + 3.0; // last beat of the section
      // trim any lead note that would clash with the run
      lead.removeWhere((n) => n.start >= base - 1e-6);
      for (var i = 0; i < 4; i++) {
        final pitch = root + 12 + _deg(lastDeg + 1 + i, scale); // ascending
        lead.add(Note(
          pitch: pitch,
          start: base + i * 0.25,
          duration: 0.23,
          velocity: (0.6 + 0.12 * i) * velEnergy,
          retrig: i == 3 ? 2 : 0, // a tiny stutter on the last step
        ));
      }
      lead.sort((a, b) => a.start.compareTo(b.start));
    }

    // BREAKDOWN: strip the backbone to bare bones for dramatic contrast — a
    // single sustained kick + sparse hat, bass holding the root, lead left to
    // ring (the master ping-pong delay tails it) — so the next chorus SLAMS.
    if (isBreak) {
      drums = <Note>[
        for (var b = 0; b < bars; b++) ...[
          Note(pitch: 36, start: b * 4.0, duration: 0.2, velocity: 0.85 * velEnergy),
          Note(pitch: 60, start: b * 4.0 + 2, duration: 0.06, velocity: 0.3 * velEnergy),
        ]
      ];
      bass = <Note>[
        for (var b = 0; b < bars; b++)
          Note(
            pitch: root - 24 + _deg(degsPerBar[b], scale),
            start: b * 4.0,
            duration: 3.8,
            velocity: 0.7 * velEnergy,
          )
      ];
      // let the last lead note ring out into the next section
      if (lead.isNotEmpty) {
        final last = lead.last;
        lead[lead.length - 1] = last.copyWith(duration: last.duration + 1.0, vib: 0.6);
      }
    }

    if (transpose != 0) {
      lead = _shift(lead, transpose);
      harmony = _shift(harmony, transpose);
      bass = _shift(bass, transpose);
    }
    final padT = transpose != 0 ? _shift(pad, transpose) : pad;
    final arpT = transpose != 0 ? _shift(arp, transpose) : arp;
    // Counter: prefer the AI's real secondary melody (RAG-informed); otherwise
    // harmonize the lead a diatonic third below (the iconic NES dual-pulse
    // lead). Present mainly in the bigger sections so verses stay clear.
    final aiCounter = _aiVoice(s['counter'], scale, root, 4);
    final List<Note> counter;
    if (aiCounter != null) {
      counter = transpose != 0 ? _shift(aiCounter, transpose) : aiCounter;
    } else if (isChorus || energy >= 0.6) {
      counter = _harmonizeBelow(lead, scale, root + transpose);
    } else {
      counter = <Note>[];
    }

    final orn = _Rng(seed ^ 0x5A17C3);
    final hum = _Rng(seed ^ 0x1B7E3D);
    // Effects EVOLVE with the section's role so the track develops sonically
    // without touching harmony: choruses sing (more vibrato + expressive
    // slides), verses/bridges get rhythmic stutters, breakdowns swell with
    // vibrato and ride the delay. Amounts still come from the RAG profile.
    final secVib = (fxVib * (0.55 + 0.85 * energy) * (isBreak ? 1.4 : 1.0))
        .clamp(0.0, 1.0);
    final leadSlide = (fxSlide * (isChorus ? 1.5 : 0.8)).clamp(0.0, 1.0);
    final backRetrig = (fxRetrig * (isChorus ? 0.6 : 1.25)).clamp(0.0, 1.0);
    final tracks = <PatternTrack>[
      PatternTrack(
          instrumentId: 'lead',
          notes: _humanize(
              _ornament(lead, orn, secVib, leadSlide, 0.0, true), hum,
              lead: true)),
      PatternTrack(
          instrumentId: 'counter',
          notes: _humanize(
              _ornament(counter, orn, secVib * 0.7, leadSlide * 0.6, 0.0, true),
              hum,
              lead: true)),
      PatternTrack(
          instrumentId: 'harmony',
          notes: _humanize(
              _ornament(harmony, orn, secVib * 0.6, 0.0, backRetrig, false),
              hum)),
      PatternTrack(instrumentId: 'bass', notes: _humanize(bass, hum)),
      PatternTrack(instrumentId: 'pad', notes: padT),
      PatternTrack(instrumentId: 'arp', notes: arpT),
      PatternTrack(instrumentId: 'drums', notes: _humanizeDrums(drums, hum)),
      PatternTrack(instrumentId: 'perc', notes: _humanizeDrums(perc, hum)),
    ];
    return Pattern(id: id, lengthBeats: bars * 4.0, tracks: tracks);
  }

  /// Generate a NEW, in-style lead from the order-2 Markov model: real 1-bar
  /// rhythms, Markov-sampled scale degrees, with each bar's first note pulled
  /// onto a chord tone so the invented melody still fits the harmony.
  List<Note> _markovLead(MarkovModel m, List<int> degsPerBar, List<int> scale,
      int root, int bars, int seed, double vel) {
    final r = _Rng(seed);
    int prev2 = 0, prev1 = 0;
    if (m.starts.isNotEmpty) {
      final s = m.starts[_wpick([for (final e in m.starts) e[2].toDouble()], r)];
      prev2 = s[0];
      prev1 = s[1];
    }
    final out = <Note>[];
    for (var b = 0; b < bars; b++) {
      final rhythm = m.rhythms[r.range(m.rhythms.length)];
      final chordDeg = degsPerBar[b];
      var first = true;
      for (final pd in rhythm) {
        if (pd.length < 2) continue;
        var deg = _markovNext(m, prev2, prev1, r);
        if (first) {
          deg = _anchorToChord(deg, chordDeg);
          first = false;
        }
        deg = deg.clamp(m.degLo, m.degHi);
        out.add(Note(
          pitch: _degToPitch(deg, scale, root),
          start: b * 4.0 + pd[0],
          duration: pd[1] <= 0 ? 0.25 : pd[1],
          velocity: (0.82 * vel).clamp(0.0, 1.0),
        ));
        prev2 = prev1;
        prev1 = deg;
      }
    }
    out.sort((a, b) => a.start.compareTo(b.start));
    return _toMono(out, 4) ?? out;
  }

  int _markovNext(MarkovModel m, int a, int b, _Rng r) {
    final next = m.trans['$a,$b'];
    if (next != null && next.isNotEmpty) {
      final i = _wpick([for (final e in next) e[1].toDouble()], r);
      return next[i][0].toInt();
    }
    return (b + const [-2, -1, 1, 2, 3, -3][r.range(6)]).clamp(m.degLo, m.degHi);
  }

  int _anchorToChord(int deg, int chordDeg) {
    final oct = (deg / 7).floor();
    final idx = deg - oct * 7; // 0..6
    final tones = [chordDeg % 7, (chordDeg + 2) % 7, (chordDeg + 4) % 7];
    var best = tones.first, bestD = 99;
    for (final t in tones) {
      final d = ((idx - t).abs()).clamp(0, 7);
      if (d < bestD) {
        bestD = d;
        best = t;
      }
    }
    return oct * 7 + best;
  }

  int _degToPitch(int deg, List<int> scale, int root) {
    final oct = (deg / 7).floor();
    final idx = deg - oct * 7; // 0..6
    return root + oct * 12 + scale[idx];
  }

  int _wpick(List<double> weights, _Rng r) {
    var total = 0.0;
    for (final w in weights) {
      total += w;
    }
    if (total <= 0) return r.range(weights.length);
    var x = r.d() * total;
    for (var i = 0; i < weights.length; i++) {
      x -= weights[i];
      if (x <= 0) return i;
    }
    return weights.length - 1;
  }

  /// Drop the bass into a proper low register so it delivers real low-end
  /// weight (chip basslines are often written an octave or two too high). Shifts
  /// the whole line by octaves until its average pitch sits around MIDI ~40.
  List<Note> _anchorBass(List<Note> bass) {
    final voiced = bass.where((n) => !n.isRest).toList();
    if (voiced.isEmpty) return bass;
    var mean = voiced.fold(0, (s, n) => s + n.pitch) / voiced.length;
    var shift = 0;
    while (mean > 47 && shift > -24) {
      shift -= 12;
      mean -= 12;
    }
    if (shift == 0) return bass;
    return [
      for (final n in bass)
        n.isRest ? n : n.copyWith(pitch: (n.pitch + shift).clamp(24, 96))
    ];
  }

  /// Make a voice feel PLAYED, not sequenced: metric accents (beat 1 strong,
  /// beat 3 medium, off-beats softer/ghosted), small velocity drift and a touch
  /// of timing push/drag. Calibrated to pro "velocity zones": down-beats accent,
  /// off-beats sit back toward ghost level. Lead keeps a gentler curve so the
  /// melody always reads; backing breathes more. Harmony intact — only velocity
  /// and tiny start offsets change.
  List<Note> _humanize(List<Note> notes, _Rng r, {bool lead = false}) {
    if (notes.isEmpty) return notes;
    final timing = lead ? 0.016 : 0.011; // beats of jitter (~5-15ms)
    final out = <Note>[];
    for (final n in notes) {
      if (n.isRest) {
        out.add(n);
        continue;
      }
      final beat = n.start % 4.0;
      final onGrid = (beat - beat.roundToDouble()).abs() < 0.06;
      double w;
      if (lead) {
        if (beat.abs() < 0.06) {
          w = 1.0;
        } else if ((beat - 2.0).abs() < 0.06) {
          w = 0.95;
        } else if (onGrid) {
          w = 0.9;
        } else {
          w = 0.85; // melody off-beats only slightly softer
        }
      } else {
        if (beat.abs() < 0.06) {
          w = 1.0;
        } else if ((beat - 2.0).abs() < 0.06) {
          w = 0.92;
        } else if (onGrid) {
          w = 0.85;
        } else {
          w = 0.74; // backing off-beats a touch softer (not heavily ghosted)
        }
      }
      w *= 0.9 + 0.16 * r.d(); // natural drift
      final jit = (r.d() - 0.5) * 2.0 * timing * (onGrid ? 0.5 : 1.0);
      final start = (n.start + jit);
      out.add(n.copyWith(
        start: start < 0 ? 0.0 : start,
        velocity: (n.velocity * w).clamp(0.0, 1.0),
      ));
    }
    return out;
  }

  /// Humanize drums like a real drummer: kick/snare keep punch, but HATS are
  /// accented when they coincide with a kick/snare hit and ghosted in between —
  /// the single biggest thing that makes programmed beats groove. Timing stays
  /// tight (only tiny jitter).
  List<Note> _humanizeDrums(List<Note> drums, _Rng r) {
    if (drums.isEmpty) return drums;
    final accents = <double>[
      for (final n in drums)
        if (!n.isRest && n.pitch <= 40) n.start // kick/snare/tom = strong hits
    ];
    bool near(double t) => accents.any((a) => (a - t).abs() < 0.03);
    final out = <Note>[];
    for (final n in drums) {
      if (n.isRest) {
        out.add(n);
        continue;
      }
      double w;
      if (n.pitch >= 42) {
        w = near(n.start) ? 1.0 : 0.55; // hats: accent on the backbeat, else ghost
      } else {
        final beat = n.start % 4.0;
        w = (beat.abs() < 0.06 || (beat - 2.0).abs() < 0.06) ? 1.0 : 0.9;
      }
      w *= 0.92 + 0.12 * r.d();
      final jit = (r.d() - 0.5) * 2.0 * 0.008; // very tight
      final start = (n.start + jit);
      out.add(n.copyWith(
        start: start < 0 ? 0.0 : start,
        velocity: (n.velocity * w).clamp(0.0, 1.0),
      ));
    }
    return out;
  }

  /// Ensure every bar of a section contains notes. Keeps whatever the AI gave
  /// and only fills the EMPTY bars with the per-song procedural [gen], so the
  /// backbone never drops out (no провалы) yet the AI's material is preserved.
  List<Note> _fillBars(
      List<Note>? voice, int bars, void Function(List<Note>, int) gen) {
    final out = List<Note>.of(voice ?? const <Note>[]);
    for (var b = 0; b < bars; b++) {
      final lo = b * 4.0;
      final hi = lo + 4.0;
      final has = out.any((n) => n.start >= lo - 1e-6 && n.start < hi - 1e-6);
      if (!has) gen(out, b);
    }
    out.sort((a, b) => a.start.compareTo(b.start));
    return out;
  }

  /// Parse an LLM melodic voice, snap into the key, force monophony.
  /// Returns null if fewer than [minNotes] usable notes.
  List<Note>? _aiVoice(dynamic raw, List<int> scale, int root, int minNotes) {
    if (raw is! List || raw.length < minNotes) return null;
    final pcs = scale.map((iv) => (root + iv) % 12).toSet();
    int snap(int p) {
      if (pcs.contains(((p % 12) + 12) % 12)) return p;
      for (final d in [1, -1, 2, -2]) {
        if (pcs.contains((((p + d) % 12) + 12) % 12)) return p + d;
      }
      return p;
    }

    final parsed = <Note>[];
    for (final n in raw) {
      final note = _parseNote(n);
      if (note == null || note.pitch < 0 || note.duration <= 0) continue;
      parsed.add(Note(
        pitch: snap(note.pitch),
        start: note.start,
        duration: note.duration,
        velocity: note.velocity,
      ));
    }
    return _toMono(parsed, minNotes);
  }

  /// A drum lane that clearly uses the documented GM kit mapping (kick 36,
  /// snare 38, tom 40, hat 42...) — the author wrote a groove on purpose, so
  /// it must not be replaced by a random RAG beat. Returns null otherwise.
  List<Note>? _aiKitDrums(dynamic raw) {
    final parsed = _aiDrums(raw, 6);
    if (parsed == null) return null;
    final kit = parsed.where((n) => n.pitch >= 35 && n.pitch <= 51).length;
    return kit >= parsed.length * 0.8 ? parsed : null;
  }

  /// Parse an LLM drum voice (noise) — keep pitches as-is, just monophonic.
  List<Note>? _aiDrums(dynamic raw, int minNotes) {
    if (raw is! List || raw.length < minNotes) return null;
    final parsed = <Note>[];
    for (final n in raw) {
      final note = _parseNote(n);
      if (note == null || note.pitch < 0 || note.duration <= 0) continue;
      parsed.add(note);
    }
    return _toMono(parsed, minNotes);
  }

  Note? _parseNote(dynamic n) {
    if (n is List && n.length >= 3) {
      return Note(
        start: _d(n[0], 0),
        pitch: _i(n[1], -1),
        duration: _d(n[2], 0.5),
        velocity: n.length >= 4 ? _d(n[3], 0.9).clamp(0.0, 1.0) : 0.9,
      );
    }
    if (n is Map) {
      return Note(
        pitch: _i(n['pitch'], -1),
        start: _d(n['start'], 0),
        duration: _d(n['duration'] ?? n['dur'], 0.5),
        velocity: _d(n['velocity'] ?? n['vel'], 0.9).clamp(0.0, 1.0),
      );
    }
    return null;
  }

  List<Note>? _toMono(List<Note> parsed, int minNotes) {
    if (parsed.length < minNotes) return null;
    parsed.sort((a, b) => a.start.compareTo(b.start));
    final out = <Note>[];
    for (final n in parsed) {
      if (out.isNotEmpty) {
        final prev = out.last;
        if (n.start <= prev.start + 1e-3) continue;
        if (prev.start + prev.duration > n.start) {
          out[out.length - 1] = Note(
            pitch: prev.pitch,
            start: prev.start,
            duration: n.start - prev.start,
            velocity: prev.velocity,
          );
        }
      }
      out.add(n);
    }
    return out.length >= minNotes ? out : null;
  }

  List<Note> _shift(List<Note> notes, int semis) => notes
      .map((n) => Note(
            pitch: n.pitch + semis,
            start: n.start,
            duration: n.duration,
            velocity: n.velocity,
          ))
      .toList();

  static int _seedFrom(dynamic title, int root, List<int> scale) {
    var h = 17;
    final t = title is String ? title : 'song';
    for (final c in t.codeUnits) {
      h = (h * 31 + c) & 0x7FFFFFFF;
    }
    h = (h * 31 + root) & 0x7FFFFFFF;
    // Hash the scale's actual intervals (its length is always 7, which
    // contributed nothing — minor vs dorian vs phrygian now matter).
    for (final iv in scale) {
      h = (h * 31 + iv) & 0x7FFFFFFF;
    }
    return h == 0 ? 12345 : h;
  }

  int _deg(int deg, List<int> scale) {
    final oct = (deg / 7).floor();
    final i = ((deg % 7) + 7) % 7;
    return oct * 12 + scale[i];
  }

  double _swing(double offset, _Style st) {
    // nudge offbeat eighths for groove
    final eighth = (offset * 2).round();
    return (eighth.isOdd) ? offset + st.swing : offset;
  }

  void _bassBar(List<Note> out, double t, int base, int deg, List<int> scale,
      double e, _Style st) {
    final root = base + _deg(deg, scale);
    final fifth = base + _deg(deg + 4, scale);
    final third = base + _deg(deg + 2, scale);
    final oct = root + 12;
    void n(int p, double o, double d, double v) =>
        out.add(Note(pitch: p, start: t + _swing(o, st), duration: d, velocity: v * e));
    switch (st.bass) {
      case 0: // half notes
        n(root, 0, 1.9, 0.85);
        n(fifth, 2, 1.9, 0.78);
        break;
      case 1: // quarters on root
        for (var b = 0; b < 4; b++) {
          n(root, b.toDouble(), 0.9, b.isEven ? 0.9 : 0.78);
        }
        break;
      case 2: // root-fifth alternation
        n(root, 0, 0.9, 0.9); n(fifth, 1, 0.9, 0.76);
        n(root, 2, 0.9, 0.85); n(fifth, 3, 0.9, 0.76);
        break;
      case 3: // walking up the chord/scale
        n(root, 0, 0.9, 0.9); n(third, 1, 0.9, 0.8);
        n(fifth, 2, 0.9, 0.85); n(oct, 3, 0.9, 0.82);
        break;
      case 4: // octave bounce (eighths)
        for (var i = 0; i < 8; i++) {
          n(i.isEven ? root : oct, i * 0.5, 0.45, i.isEven ? 0.9 : 0.6);
        }
        break;
      case 5: // syncopated
        n(root, 0, 0.7, 0.9); n(root, 0.75, 0.6, 0.7);
        n(fifth, 1.5, 0.5, 0.78); n(root, 2, 0.7, 0.88);
        n(oct, 2.75, 0.5, 0.6); n(fifth, 3.5, 0.5, 0.72);
        break;
      default: // driving eighths on root
        for (var i = 0; i < 8; i++) {
          n(root, i * 0.5, 0.45, i.isEven ? 0.88 : 0.66);
        }
    }
  }

  void _harmonyBar(List<Note> out, double t, int base, int deg, List<int> scale,
      double e, _Style st) {
    final offs = [0, 2, 4, 7, 9];
    final tones = [for (final o in offs) base + _deg(deg + o, scale)];
    final pat = st.arp;
    final step = st.harmonyStep;
    final n = (4 / step).round();
    for (var i = 0; i < n; i++) {
      final pitch = tones[pat[i % pat.length] % tones.length];
      final on = i * step;
      final accent = (on - on.floorToDouble()) < 1e-6; // on a beat
      out.add(Note(
        pitch: pitch,
        start: t + _swing(on, st),
        duration: step * 0.92,
        velocity: (accent ? 0.55 : 0.4) * e,
      ));
    }
  }

  /// Harmonize a melodic line a diatonic third below, snapped into the key —
  /// the classic NES two-pulse "dual lead". Softer than the lead so it backs it.
  List<Note> _harmonizeBelow(List<Note> melody, List<int> scale, int root) {
    final pcs = scale.map((iv) => (root + iv) % 12).toSet();
    int snapDown(int p) {
      for (final d in [0, -1, -2]) {
        if (pcs.contains((((p + d) % 12) + 12) % 12)) return p + d;
      }
      return p;
    }

    return [
      for (final n in melody)
        Note(
          pitch: snapDown(n.pitch - 3),
          start: n.start,
          duration: n.duration,
          velocity: n.velocity * 0.7,
        )
    ];
  }

  /// Loop a real RAG drum groove into one bar.
  void _grooveBar(List<Note> out, double t, GrooveBeat beat, double e) {
    for (final n in beat.notes) {
      if (n.length < 4) continue;
      out.add(Note(
        pitch: n[1].round(),
        start: t + n[0],
        duration: n[2] <= 0 ? 0.2 : n[2],
        velocity: (n[3] * e).clamp(0.0, 1.0),
      ));
    }
  }

  /// Apply a real RAG melodic pattern (rhythm + contour) onto this bar's chord
  /// root, snapped into the key. Used for bass, harmony and arp lines.
  void _contourBar(List<Note> out, double t, int base, int deg, List<int> scale,
      List<List<double>> pattern, double e) {
    final rootPitch = base + _deg(deg, scale);
    final pcs = scale.map((iv) => (base + iv) % 12).toSet();
    int snap(int p) {
      if (pcs.contains(((p % 12) + 12) % 12)) return p;
      for (final d in [1, -1, 2, -2]) {
        if (pcs.contains((((p + d) % 12) + 12) % 12)) return p + d;
      }
      return p;
    }

    for (final n in pattern) {
      if (n.length < 4) continue;
      out.add(Note(
        pitch: snap(rootPitch + n[1].round()),
        start: t + n[0],
        duration: n[2] <= 0 ? 0.4 : n[2],
        velocity: (n[3] * e).clamp(0.0, 1.0),
      ));
    }
  }

  void _percBar(List<Note> out, double t, double e, _Style st) {
    // A brighter shaker/hi-hat layer on offbeat 16ths — extra groove on top of
    // the kick/snare drum channel, panned slightly for width.
    for (var i = 0; i < 8; i++) {
      final on = i * 0.5 + 0.25; // offbeats
      if (on >= 4.0) break;
      out.add(Note(
        pitch: 64, // brighter noise tone than the main hats
        start: t + on,
        duration: 0.05,
        velocity: (i.isEven ? 0.32 : 0.22) * e,
      ));
    }
  }

  void _padBar(List<Note> out, double t, int base, int deg, List<int> scale,
      double e, List<int>? voicing) {
    // A sustained chord held across the whole bar — the harmonic bed that gives
    // the track 16-bit fullness. Uses a REAL chord voicing (interval shape mined
    // from chiptunes) when available, snapped into the key; else a plain triad.
    final rootPitch = base + _deg(deg, scale);
    final pcs = scale.map((iv) => (base + iv) % 12).toSet();
    int snap(int p) {
      if (pcs.contains(((p % 12) + 12) % 12)) return p;
      for (final d in [1, -1, 2, -2]) {
        if (pcs.contains((((p + d) % 12) + 12) % 12)) return p + d;
      }
      return p;
    }

    final intervals = (voicing != null && voicing.length >= 3)
        ? voicing
        : const [0, 4, 7];
    for (final iv in intervals) {
      out.add(Note(
        pitch: snap(rootPitch + iv),
        start: t,
        duration: 3.9,
        velocity: 0.30 * e,
      ));
    }
  }

  /// Decorate a melodic voice with tracker per-note effects, with the amounts
  /// decided by the RAG profile: vibrato on sustained notes, gentle pitch
  /// slides on long lead notes, retriggers/stutters on short backing notes.
  List<Note> _ornament(List<Note> notes, _Rng r, double vibP, double slideP,
      double retrigP, bool lead) {
    if (notes.isEmpty) return notes;
    return [
      for (final n in notes)
        if (n.isRest)
          n
        else
          n.copyWith(
            vib: (n.duration >= 0.45 && r.chance(vibP))
                ? 0.4 + 0.4 * r.d()
                : n.vib,
            slide: (lead && n.duration >= 0.9 && r.chance(slideP * 0.5))
                ? (r.chance(0.5) ? -2.0 : 2.0)
                : n.slide,
            retrig: (!lead && n.duration <= 0.5 && r.chance(retrigP * 0.5))
                ? 2 + r.range(3)
                : n.retrig,
          )
    ];
  }

  /// True hardware (tracker) arpeggio: one held note per beat that the engine
  /// rapidly cycles through the chord — a full chord on a single channel, the
  /// signature NES/MOD sound.
  void _chipArpBar(List<Note> out, double t, int base, int deg, List<int> scale,
      double e) {
    final r0 = _deg(deg, scale);
    final third = _deg(deg + 2, scale) - r0;
    final fifth = _deg(deg + 4, scale) - r0;
    for (var b = 0; b < 4; b++) {
      out.add(Note(
        pitch: base + r0,
        start: t + b,
        duration: 0.95,
        velocity: 0.42 * e,
        arp: [third, fifth],
      ));
    }
  }

  void _arpBar(List<Note> out, double t, int base, int deg, List<int> scale,
      double e, _Style st) {
    // Fast arpeggio over the chord tones — classic chiptune sparkle/motion.
    final tones = [for (final o in const [0, 2, 4, 7]) base + _deg(deg + o, scale)];
    const step = 0.25; // 16ths
    final n = (4 / step).round();
    for (var i = 0; i < n; i++) {
      final pitch = tones[st.arp[i % st.arp.length] % tones.length];
      out.add(Note(
        pitch: pitch,
        start: t + i * step,
        duration: step * 0.9,
        velocity: (i.isEven ? 0.36 : 0.26) * e,
      ));
    }
  }

  void _drumBar(List<Note> out, double t, double e, bool last, _Style st) {
    void hit(int p, double o, double d, double v) =>
        out.add(Note(pitch: p, start: t + o, duration: d, velocity: v * e));
    final g = st.drum;
    // kick + snare patterns
    if (g == 0 || g == 3) {
      hit(36, 0, 0.18, 0.95); hit(36, 2, 0.18, 0.85);
      hit(38, 1, 0.13, 0.82); if (!last) hit(38, 3, 0.13, 0.82);
    } else if (g == 1) { // four on floor
      for (var b = 0; b < 4; b++) {
        hit(36, b.toDouble(), 0.16, 0.9);
      }
      hit(38, 1, 0.13, 0.8); hit(38, 3, 0.13, 0.8);
    } else if (g == 2) { // half time
      hit(36, 0, 0.2, 0.95); hit(38, 2, 0.14, 0.85);
    } else if (g == 4) { // driving eighth kicks
      for (var i = 0; i < 8; i++) {
        if (i != 2 && i != 6) hit(36, i * 0.5, 0.14, i.isEven ? 0.9 : 0.6);
      }
      hit(38, 1, 0.13, 0.82); hit(38, 3, 0.13, 0.82);
    } else { // sparse / breaky
      hit(36, 0, 0.2, 0.95); hit(36, 1.5, 0.16, 0.7);
      hit(38, 2, 0.14, 0.85);
    }
    // hats: density from style
    final hstep = st.hatStep;
    final hn = (4 / hstep).round();
    for (var i = 0; i < hn; i++) {
      out.add(Note(pitch: 60, start: t + i * hstep, duration: 0.06,
          velocity: (i.isEven ? 0.42 : 0.26) * e));
    }
    if (last) {
      for (var i = 0; i < 4; i++) {
        hit(40, 3 + i * 0.25, 0.12, 0.6 + i * 0.12);
      }
    }
  }

  static double _d(dynamic v, double f) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? f;
    return f;
  }

  static int _i(dynamic v, int f) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? f;
    return f;
  }

  static String _str(dynamic v, String f) {
    if (v is String && v.trim().isNotEmpty) return v.trim();
    return f;
  }
}

/// Tiny deterministic RNG so a song's style is stable but unique.
class _Rng {
  int _s;
  _Rng(int seed) : _s = (seed & 0x7FFFFFFF) | 1;
  int next() {
    _s ^= (_s << 13) & 0x7FFFFFFF;
    _s ^= _s >> 17;
    _s ^= (_s << 5) & 0x7FFFFFFF;
    return _s & 0x7FFFFFFF;
  }

  int range(int n) => next() % n;
  double d() => next() / 0x7FFFFFFF;
  bool chance(double p) => d() < p;
  T pick<T>(List<T> xs) => xs[range(xs.length)];
}

/// A per-song accompaniment "style": which arpeggio shape, bass groove, drum
/// pattern, hat density and swing, PLUS the instrument timbres (waveforms,
/// pulse widths, envelopes, stereo placement). Picked from the song seed so
/// every track has its own backing AND its own sound — no fixed template.
class _Style {
  final List<int> arp;
  final double harmonyStep; // 0.25 (16ths) or 0.5 (8ths)
  final int bass; // 0..6
  final int drum; // 0..5
  final double hatStep; // 0.25 or 0.5
  final double swing; // 0 .. ~0.1

  // Timbre palette
  final Waveform leadWave;
  final double leadDuty;
  final Envelope leadEnv;
  final Waveform harmWave;
  final double harmDuty;
  final Envelope harmEnv;
  final Waveform bassWave;
  final Waveform padWave; // sustained chord bed (16-bit fullness)
  final Waveform arpWave; // arpeggio sparkle
  final double arpDuty;
  final Waveform counterWave; // harmonized dual-lead (2nd pulse)
  final double counterDuty;
  final double pan; // stereo spread; lead one side, harmony the other
  final double glideSec; // portamento time for the lead/counter (0 = off)
  final double leadDrive; // overdrive on the lead/counter (0 = clean)
  final double bassDrive; // overdrive on the bass
  final double drumTone; // 0 = hiss .. 1 = metallic ring (kick/snare channel)
  final double percTone; // shaker/hat brightness
  final double leadCrush; // lo-fi bitcrush on the lead (0 = off)
  final double padTrem; // tremolo wobble on the pad
  final double arpTrem; // tremolo wobble on the arp
  final bool chipArp; // arp voice uses true hardware (tracker) arpeggio

  const _Style(
    this.arp,
    this.harmonyStep,
    this.bass,
    this.drum,
    this.hatStep,
    this.swing,
    this.leadWave,
    this.leadDuty,
    this.leadEnv,
    this.harmWave,
    this.harmDuty,
    this.harmEnv,
    this.bassWave,
    this.padWave,
    this.arpWave,
    this.arpDuty,
    this.counterWave,
    this.counterDuty,
    this.pan,
    this.glideSec,
    this.leadDrive,
    this.bassDrive,
    this.drumTone,
    this.percTone,
    this.leadCrush,
    this.padTrem,
    this.arpTrem,
    this.chipArp,
  );

  static const _arps = <List<int>>[
    [0, 1, 2, 3, 2, 1],
    [0, 1, 2, 3],
    [3, 2, 1, 0],
    [0, 2, 1, 3],
    [0, 3, 1, 4],
    [0, 2, 4, 2],
    [0, 1, 0, 2],
    [4, 2, 0, 2, 4, 3],
    [0, 4, 2, 4],
  ];

  // (waveform, duty) lead voices — bright/buzzy variety plus softer colours,
  // so leads range from thin NES pulses to fat saws to flute-like triangles.
  static const _leadVoices = <(Waveform, double)>[
    (Waveform.pulse, 0.5),
    (Waveform.pulse, 0.33),
    (Waveform.pulse, 0.25),
    (Waveform.pulse, 0.18),
    (Waveform.pulse, 0.125),
    (Waveform.sawtooth, 0.5),
    (Waveform.square, 0.5),
    (Waveform.triangle, 0.5),
  ];
  // Harmony/counter voices — thinner so they sit under the lead.
  static const _harmVoices = <(Waveform, double)>[
    (Waveform.pulse, 0.25),
    (Waveform.pulse, 0.125),
    (Waveform.pulse, 0.5),
    (Waveform.pulse, 0.33),
    (Waveform.triangle, 0.5),
    (Waveform.sine, 0.5),
    (Waveform.sawtooth, 0.5),
  ];
  static const _bassWaves = <Waveform>[
    Waveform.triangle,
    Waveform.pulse,
    Waveform.sawtooth,
    Waveform.square,
    Waveform.sine,
  ];
  static const _padWaves = <Waveform>[
    Waveform.triangle,
    Waveform.sine,
    Waveform.pulse,
    Waveform.sawtooth,
  ];
  static const _arpVoices = <(Waveform, double)>[
    (Waveform.pulse, 0.125),
    (Waveform.pulse, 0.25),
    (Waveform.pulse, 0.33),
    (Waveform.square, 0.5),
    (Waveform.triangle, 0.5),
  ];
  // Lead amplitude shapes: pluck / sustained / stab / swell / bell.
  static const _leadEnvs = <Envelope>[
    Envelope(attack: 0.002, decay: 0.06, sustain: 0.45, release: 0.09),
    Envelope(attack: 0.004, decay: 0.04, sustain: 0.78, release: 0.13),
    Envelope(attack: 0.001, decay: 0.10, sustain: 0.25, release: 0.06),
    Envelope(attack: 0.030, decay: 0.08, sustain: 0.70, release: 0.20),
    Envelope(attack: 0.001, decay: 0.25, sustain: 0.15, release: 0.18),
  ];
  static const _harmEnvs = <Envelope>[
    Envelope(attack: 0.004, decay: 0.08, sustain: 0.45, release: 0.10),
    Envelope(attack: 0.006, decay: 0.05, sustain: 0.6, release: 0.14),
    Envelope(attack: 0.015, decay: 0.10, sustain: 0.55, release: 0.18),
  ];

  factory _Style.pick(int seed) {
    final r = _Rng(seed ^ 0xA17C5);
    final lead = r.pick(_leadVoices);
    final harm = r.pick(_harmVoices);
    final arpv = r.pick(_arpVoices);
    final ctr = r.pick(_leadVoices);
    return _Style(
      r.pick(_arps),
      r.chance(0.5) ? 0.25 : 0.5,
      r.range(7),
      r.range(6),
      r.chance(0.45) ? 0.25 : 0.5,
      r.chance(0.4) ? (0.05 + 0.05 * r.d()) : 0.0,
      lead.$1,
      lead.$2,
      r.pick(_leadEnvs),
      harm.$1,
      harm.$2,
      r.pick(_harmEnvs),
      r.pick(_bassWaves),
      r.pick(_padWaves),
      arpv.$1,
      arpv.$2,
      ctr.$1,
      ctr.$2,
      0.12 + 0.18 * r.d(), // 0.12..0.30 spread
      r.chance(0.45) ? (0.035 + 0.035 * r.d()) : 0.0, // glide on ~45% of songs
      r.chance(0.4) ? (0.2 + 0.5 * r.d()) : 0.0, // leadDrive (gritty leads)
      r.chance(0.45) ? (0.15 + 0.35 * r.d()) : 0.0, // bassDrive
      0.1 + 0.85 * r.d(), // drumTone: hiss .. ring (varies per track)
      (0.45 + 0.5 * r.d()).clamp(0.0, 1.0), // percTone: brighter shaker/hat
      r.chance(0.25) ? (0.3 + 0.4 * r.d()) : 0.0, // leadCrush (lo-fi lead)
      r.chance(0.5) ? (0.2 + 0.4 * r.d()) : 0.0, // padTrem (wobble pad)
      r.chance(0.35) ? (0.25 + 0.4 * r.d()) : 0.0, // arpTrem (wobble arp)
      r.chance(0.4), // chipArp: true hardware arpeggio on ~40% of tracks
    );
  }

  // timbre keyword -> (lead waveform, duty). Lets the data-derived GM family
  // pick the lead's sound; falls back to this song's random palette.
  static const _timbres = <String, (Waveform, double)>{
    'square': (Waveform.pulse, 0.5),
    'saw': (Waveform.sawtooth, 0.5),
    'brass': (Waveform.sawtooth, 0.5),
    'string': (Waveform.triangle, 0.5),
    'organ': (Waveform.pulse, 0.5),
    'reed': (Waveform.pulse, 0.25),
    'mellow': (Waveform.triangle, 0.5),
    'bright': (Waveform.pulse, 0.25),
  };

  /// The voices, timbred for THIS song. Beyond the 4 NES channels we add a
  /// harmonized COUNTER (dual-lead), a sustained PAD (chord bed), an ARP layer
  /// and a separate PERC channel — eight voices for a full, 16-bit-era texture.
  /// [timbre] (from the dataset's GM family) steers the lead's sound when given.
  List<Instrument> instruments(
      {String? timbre,
      double? beatTone,
      _Production? prod,
      _Production? profile,
      _Rng? rng,
      String? Function(String id)? sampleOf}) {
    final p = prod;
    final pr = profile;
    final r = rng ?? _Rng(0x51ED27);
    // Timbre from the dataset is only a BIAS, not a dictate: the tag pool is
    // tiny (8 words, 'bright' dominates), so hard-mapping it re-used the same
    // 2-3 lead sounds on most tracks. An explicit AI leadTimbre still wins;
    // a dataset tag is honored ~40% of the time, else the seeded palette.
    final (Waveform, double)? t = p?.leadTimbre != null
        ? _timbres[p!.leadTimbre]
        : (r.chance(0.4) ? _timbres[timbre] : null);
    final lw = t?.$1 ?? leadWave;
    // Jitter the duty of a timbre-mapped pulse so even "bright" leads differ.
    final ld = t != null
        ? (t.$1 == Waveform.pulse
            ? (t.$2 * (0.7 + 0.6 * r.d())).clamp(0.10, 0.5).toDouble()
            : t.$2)
        : leadDuty;
    final cw = t != null ? Waveform.pulse : counterWave;
    final cd = t != null ? (ld <= 0.3 ? 0.125 : 0.25) : counterDuty;
    // Priority for every knob: explicit AI production wins outright; the RAG
    // profile is only a TENDENCY blended with this song's seeded style plus
    // jitter. (The mined profiles saturate at identical clamped values for
    // ~90% of songs, so "profile ?? style" used to give every track the same
    // drive/filter/crush — the #1 reason tracks all sounded alike.)
    double knob(double? ai, double? prof, double styleV) {
      if (ai != null) return ai.clamp(0.0, 1.0).toDouble();
      if (prof == null) return styleV.clamp(0.0, 1.0).toDouble();
      final w = 0.25 + 0.5 * r.d(); // profile weight 0.25..0.75
      final v = prof * w + styleV * (1 - w) + (r.d() - 0.5) * 0.2;
      return v.clamp(0.0, 1.0).toDouble();
    }

    final eDrive = knob(p?.leadDrive, pr?.leadDrive, leadDrive);
    final eCrush = knob(p?.leadCrush, pr?.leadCrush, leadCrush);
    final eGlide = knob(p?.leadGlide, pr?.leadGlide, glideSec / 0.07) * 0.07;
    final eBassWave = p?.bassWave ?? bassWave;
    final eBassDrive = knob(p?.bassDrive, pr?.bassDrive, bassDrive);
    final eDrumTone = knob(p?.drumsTone, beatTone ?? pr?.drumsTone, drumTone);
    final ePercTone = knob(p?.percTone, pr?.percTone, percTone);
    final ePadWave = p?.padWave ?? padWave;
    final ePadTrem = knob(p?.padTrem, pr?.padTrem, padTrem);
    final eArpWave = p?.arpWave ?? arpWave;
    final eArpTrem = knob(p?.arpTrem, pr?.arpTrem, arpTrem);
    // Filter: style has no cutoff of its own, so the blend target is a mostly
    // open, per-song random position — the profile pulls it darker/squelchier.
    final eCut = knob(p?.cutoff, pr?.cutoff, 0.7 + 0.3 * r.d());
    final eRes = knob(p?.resonance, pr?.resonance, 0.5 * r.d());
    final eFenv = knob(p?.filterEnv, pr?.filterEnv, 0.6 * r.d());
    return [
        Instrument(
          id: 'lead',
          sample: sampleOf?.call('lead'),
          waveform: lw,
          duty: ld,
          volume: 0.85,
          pan: pan,
          glide: eGlide,
          drive: eDrive,
          crush: eCrush,
          cutoff: eCut,
          resonance: eRes,
          filterEnv: eFenv,
          envelope: leadEnv,
        ),
        Instrument(
          id: 'counter',
          sample: sampleOf?.call('counter'),
          waveform: cw,
          duty: cd,
          volume: 0.5,
          pan: -pan * 0.8,
          glide: eGlide,
          drive: eDrive * 0.8,
          envelope: leadEnv,
        ),
        Instrument(
          id: 'harmony',
          sample: sampleOf?.call('harmony'),
          waveform: harmWave,
          duty: harmDuty,
          volume: 0.5,
          pan: -pan,
          // sit a touch under the lead: roll off the brightest highs so the
          // melody owns the 1-5 kHz presence band (cleaner mids, less masking).
          cutoff: 0.8,
          envelope: harmEnv,
        ),
        Instrument(
          id: 'bass',
          sample: sampleOf?.call('bass'),
          waveform: eBassWave,
          duty: 0.5,
          volume: 0.95,
          drive: eBassDrive,
          cutoff: eCut,
          resonance: eRes * 0.7,
          filterEnv: eFenv * 0.8,
          envelope: const Envelope(
              attack: 0.002, decay: 0.05, sustain: 0.85, release: 0.06),
        ),
        Instrument(
          id: 'pad',
          sample: sampleOf?.call('pad'),
          waveform: ePadWave,
          duty: 0.5,
          volume: 0.34,
          pan: pan * 0.5,
          // the pad is a low/mid harmonic bed — keep it dark so it never
          // competes with the lead or clutters the mids.
          cutoff: 0.5,
          trem: ePadTrem,
          envelope: const Envelope(
              attack: 0.04, decay: 0.2, sustain: 0.7, release: 0.4),
        ),
        Instrument(
          id: 'arp',
          sample: sampleOf?.call('arp'),
          waveform: eArpWave,
          duty: arpDuty,
          volume: 0.42,
          pan: -pan * 0.7,
          trem: eArpTrem,
          envelope: const Envelope(
              attack: 0.002, decay: 0.04, sustain: 0.3, release: 0.05),
        ),
        Instrument(
          id: 'drums',
          sample: sampleOf?.call('drums'),
          waveform: Waveform.noise,
          volume: 0.72,
          tone: eDrumTone,
          envelope: const Envelope(
              attack: 0.001, decay: 0.005, sustain: 1.0, release: 0.02),
        ),
        Instrument(
          id: 'perc',
          sample: sampleOf?.call('perc'),
          waveform: Waveform.noise,
          volume: 0.32,
          pan: 0.25,
          tone: ePercTone,
          envelope: const Envelope(
              attack: 0.001, decay: 0.005, sustain: 1.0, release: 0.02),
        ),
      ];
  }
}

/// The AI's tasteful production choices (HOW the track should sound). Any field
/// the model omits falls back to the per-song seeded [_Style].
class _Production {
  final String? leadTimbre;
  final double? leadDrive;
  final double? leadCrush;
  final double? leadGlide;
  final Waveform? bassWave;
  final double? bassDrive;
  final double? drumsTone;
  final double? percTone;
  final Waveform? padWave;
  final double? padTrem;
  final Waveform? arpWave;
  final double? arpTrem;
  final double? delay;
  final double? cutoff;
  final double? resonance;
  final double? filterEnv;

  const _Production({
    this.leadTimbre,
    this.leadDrive,
    this.leadCrush,
    this.leadGlide,
    this.bassWave,
    this.bassDrive,
    this.drumsTone,
    this.percTone,
    this.padWave,
    this.padTrem,
    this.arpWave,
    this.arpTrem,
    this.delay,
    this.cutoff,
    this.resonance,
    this.filterEnv,
  });

  static _Production parse(dynamic raw) {
    if (raw is! Map) return const _Production();
    double? d(String k) {
      final v = raw[k];
      if (v is num) return v.toDouble().clamp(0.0, 1.0);
      if (v is String) {
        final p = double.tryParse(v);
        return p?.clamp(0.0, 1.0);
      }
      return null;
    }

    Waveform? w(String k, List<Waveform> allowed) {
      final v = raw[k];
      if (v is String && v.trim().isNotEmpty) {
        final wf = Waveform.fromWire(v.trim());
        if (allowed.contains(wf)) return wf;
      }
      return null;
    }

    final lt = raw['leadTimbre'];
    return _Production(
      leadTimbre: lt is String && lt.trim().isNotEmpty ? lt.trim().toLowerCase() : null,
      leadDrive: d('leadDrive'),
      leadCrush: d('leadCrush'),
      leadGlide: d('leadGlide'),
      bassWave: w('bassWave',
          const [Waveform.triangle, Waveform.pulse, Waveform.sawtooth]),
      bassDrive: d('bassDrive'),
      drumsTone: d('drumsTone'),
      percTone: d('percTone'),
      padWave:
          w('padWave', const [Waveform.triangle, Waveform.sine, Waveform.pulse]),
      padTrem: d('padTrem'),
      arpWave: w('arpWave', const [Waveform.pulse, Waveform.square]),
      arpTrem: d('arpTrem'),
      delay: d('delay'),
      cutoff: d('cutoff'),
      resonance: d('resonance'),
      filterEnv: d('filterEnv') ?? d('filter_env'),
    );
  }
}
