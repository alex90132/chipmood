import '../../domain/entities/note.dart';

/// Tiny deterministic RNG (xorshift) so a given song always renders the same.
class _Rng {
  int _s;
  _Rng(int seed) : _s = (seed == 0 ? 0x9E3779B9 : seed) & 0x7FFFFFFF;
  int next() {
    _s ^= (_s << 13) & 0x7FFFFFFF;
    _s ^= _s >> 17;
    _s ^= (_s << 5) & 0x7FFFFFFF;
    return _s & 0x7FFFFFFF;
  }

  double d() => next() / 0x7FFFFFFF;
  int range(int n) => next() % n;
  bool chance(double p) => d() < p;
  T pick<T>(List<T> xs) => xs[range(xs.length)];
}

/// A rhythm template: note (offsetBeat, durBeat) pairs spanning one 4-beat bar.
typedef _Rhythm = List<List<double>>;

/// Generates singable, "soulful" lead melodies: chord-tone anchored on strong
/// beats, stepwise (Markov) motion between, phrase arches, call-and-response
/// rests, and a recurring CHORUS HOOK that gets developed — the things that
/// make a melody memorable rather than random.
class MelodyEngine {
  final List<int> scale;
  final int register; // MIDI of the melodic octave base (~ tonic + 12)
  MelodyEngine({required this.scale, required this.register});

  static const _verseRhythms = <_Rhythm>[
    [[0, 1], [1, 1], [2, 1.5], [3.5, 0.5]],
    [[0, 1.5], [1.5, 0.5], [2, 1], [3, 1]],
    [[0, 1], [1, 0.5], [1.5, 0.5], [2, 2]],
  ];
  static const _chorusRhythms = <_Rhythm>[
    [[0, 1], [1, 0.5], [1.5, 0.5], [2, 1], [3, 0.5], [3.5, 0.5]],
    [[0, 0.5], [0.5, 0.5], [1, 1], [2, 0.5], [2.5, 0.5], [3, 1]],
    [[0, 0.75], [0.75, 0.75], [1.5, 0.5], [2, 1], [3, 1]],
  ];

  int _semi(int deg) {
    final oct = (deg / 7).floor();
    final i = ((deg % 7) + 7) % 7;
    return oct * 12 + scale[i];
  }

  int _pitch(int deg) => register + _semi(deg);

  /// Pick the chord tone (scale degree) closest to [prevDeg] for smooth motion.
  int _nearestChordTone(int chordDeg, int prevDeg, _Rng rng, {bool soar = false}) {
    final tones = [chordDeg, chordDeg + 2, chordDeg + 4, chordDeg + 7];
    if (soar && rng.chance(0.5)) return chordDeg + 4; // leap up on big downbeats
    tones.sort((a, b) => (a - prevDeg).abs().compareTo((b - prevDeg).abs()));
    // mostly nearest, sometimes the 2nd-nearest for variety
    return rng.chance(0.75) ? tones[0] : tones[1];
  }

  int _markovStep(_Rng rng) {
    final r = rng.d();
    if (r < 0.34) return 1;
    if (r < 0.68) return -1;
    if (r < 0.80) return 2;
    if (r < 0.90) return -2;
    if (r < 0.96) return 0;
    return rng.chance(0.5) ? 3 : -3;
  }
}

extension MelodyGen on MelodyEngine {
  /// Build a recurring hook contour (relative scale-degree steps) for choruses.
  List<int> makeHook(int seed) {
    final rng = _Rng(seed ^ 0x51ED2C);
    // Start at a chord tone offset, arch up then resolve down — memorable shape.
    final shapes = <List<int>>[
      [0, 2, 4, 2, 0, -1, 0],
      [0, 1, 2, 4, 2, 1, 0],
      [4, 2, 0, 2, 4, 5, 4],
      [0, -1, 0, 2, 4, 3, 2],
    ];
    return rng.pick(shapes);
  }

  /// Generate a section's lead melody.
  List<Note> generate({
    required List<int> chordDegsPerBar,
    required int bars,
    required double energy,
    required int seed,
    required bool isChorus,
    required List<int> hook,
  }) {
    final rng = _Rng(seed);
    final notes = <Note>[];
    int prevDeg = chordDegsPerBar.isEmpty ? 0 : chordDegsPerBar[0];

    for (int b = 0; b < bars; b++) {
      final chordDeg = chordDegsPerBar[b % chordDegsPerBar.length];
      final rhythm = isChorus
          ? rng.pick(MelodyEngine._chorusRhythms)
          : rng.pick(MelodyEngine._verseRhythms);
      final lastBarOfPhrase = (b % 2) == 1;

      for (int i = 0; i < rhythm.length; i++) {
        final off = rhythm[i][0];
        final dur = rhythm[i][1];
        final t = b * 4 + off;
        final strong = off == 0 || off == 2;
        final phraseEnd = lastBarOfPhrase && i == rhythm.length - 1;

        // Call-and-response: rest at some phrase ends (more in verses).
        if (phraseEnd && rng.chance(isChorus ? 0.2 : 0.45)) {
          prevDeg = chordDeg; // re-anchor after the breath
          continue;
        }

        int deg;
        if (isChorus && strong && i < hook.length) {
          // State the hook (relative to the bar's chord), giving memorability.
          deg = chordDeg + hook[(b * 2 + i) % hook.length];
        } else if (strong) {
          deg = _nearestChordTone(chordDeg, prevDeg, rng, soar: isChorus && off == 0);
        } else {
          deg = prevDeg + _markovStep(rng);
          // gentle pull back toward a chord tone if we drifted far
          if ((deg - chordDeg).abs() > 6) deg = chordDeg + (deg > chordDeg ? 4 : 0);
        }
        // keep within a comfortable ~1.5 octave register
        if (deg < -2) deg += 7;
        if (deg > 11) deg -= 7;

        final vel = ((strong ? 0.95 : 0.82) * energy) *
            (0.92 + 0.08 * rng.d());
        notes.add(Note(
          pitch: _pitch(deg),
          start: t,
          duration: dur * 0.96,
          velocity: vel.clamp(0.0, 1.0),
        ));
        prevDeg = deg;
      }
    }
    return notes;
  }
}
