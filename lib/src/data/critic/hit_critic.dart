import 'dart:math' as math;

import '../../domain/entities/composition.dart';
import '../../domain/entities/note.dart';
import '../../domain/entities/pattern.dart';

/// Judges how much a composition sounds like a HIT, purely from the notes —
/// no audio needed, so scoring is instant.
///
/// The trick that makes the app "only output hits": the composer generates
/// MANY candidate tracks per tap, this critic scores each one, and the user
/// only ever hears the winner. The duds still exist — they're just never
/// played. (Same rejection-sampling idea pro tools use.)
///
/// Every rule below is a property that separates memorable game themes from
/// random-note noodling:
///  * hook       — the lead repeats a motif (bars 3-4 restate bars 1-2, and the
///                 chorus recurs across the arrangement);
///  * singable   — mostly stepwise motion, leaps recover, comfortable range;
///  * consonant  — lead agrees with the bass on strong beats;
///  * groove     — drums keep ONE pattern; the bass locks with the kick;
///  * breathing  — density in the sweet spot, real rests between phrases;
///  * dynamics   — the chorus actually lifts above the verse.
class HitCritic {
  const HitCritic();

  /// Overall score 0..1. Composed as a weighted sum of the sub-scores.
  double score(Composition c) {
    final s = breakdown(c);
    return s.values.fold(0.0, (a, b) => a + b) / _weightsTotal;
  }

  static const _weights = <String, double>{
    'hook': 3.0,
    'singable': 2.0,
    'consonant': 2.0,
    'groove': 1.5,
    'breathing': 1.0,
    'dynamics': 0.5,
  };
  static final _weightsTotal =
      _weights.values.fold(0.0, (a, b) => a + b);

  /// Per-criterion weighted scores (each 0..weight). Exposed for tests/debug.
  Map<String, double> breakdown(Composition c) {
    final leadBars = _bars(c, 'lead');
    final drumBars = _bars(c, 'drums');
    return {
      'hook': _weights['hook']! * _hook(c),
      'singable': _weights['singable']! * _singable(leadBars),
      'consonant': _weights['consonant']! * _consonant(c),
      'groove': _weights['groove']! * _groove(c, drumBars),
      'breathing': _weights['breathing']! * _breathing(leadBars),
      'dynamics': _weights['dynamics']! * _dynamics(c),
    };
  }

  // ---- hook: motif repetition inside sections + chorus recurrence ----------

  double _hook(Composition c) {
    var motif = 0.0;
    var n = 0;
    for (final p in c.patterns) {
      final lead = _voice(p, 'lead');
      if (lead.length < 6) continue;
      final len = _len(p);
      if (len < 16) continue; // need 4 bars to compare halves
      final a = _rhythmContour(lead, 0, len / 2);
      final b = _rhythmContour(lead, len / 2, len);
      if (a.isEmpty || b.isEmpty) continue;
      motif += _similarity(a, b);
      n++;
    }
    final motifScore = n == 0 ? 0.3 : motif / n;

    // The chorus (or any section) must RETURN in the arrangement.
    final counts = <String, int>{};
    for (final id in c.arrangement) {
      counts[id] = (counts[id] ?? 0) + 1;
    }
    final repeats = counts.values.where((v) => v >= 2).length;
    final returnScore = c.arrangement.length < 3
        ? 0.5
        : (repeats / math.max(1, counts.length)).clamp(0.0, 1.0);

    return 0.65 * motifScore + 0.35 * returnScore;
  }

  // ---- singable: stepwise motion, recovering leaps, tessitura --------------

  double _singable(Map<Pattern, List<Note>> leadBars) {
    final notes = leadBars.values.expand((x) => x).toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    if (notes.length < 8) return 0.2;
    var steps = 0, wildLeaps = 0, repeats = 0, maxRun = 0, run = 0;
    for (var i = 1; i < notes.length; i++) {
      final iv = (notes[i].pitch - notes[i - 1].pitch).abs();
      if (iv == 0) {
        repeats++;
        run++;
        maxRun = math.max(maxRun, run);
      } else {
        run = 0;
      }
      if (iv >= 1 && iv <= 2) steps++;
      if (iv > 9) {
        // a big leap is fine if the line steps back afterwards
        final recovered = i + 1 < notes.length &&
            (notes[i + 1].pitch - notes[i].pitch).abs() <= 2 &&
            (notes[i + 1].pitch - notes[i].pitch).sign !=
                (notes[i].pitch - notes[i - 1].pitch).sign;
        if (!recovered) wildLeaps++;
      }
    }
    final total = notes.length - 1;
    final stepScore = (steps / total / 0.45).clamp(0.0, 1.0);
    final leapPenalty = (wildLeaps / total / 0.12).clamp(0.0, 1.0);
    final repeatPenalty = maxRun >= 5 ? 0.5 : (repeats / total / 0.6).clamp(0.0, 1.0) * 0.3;

    final pitches = notes.map((n) => n.pitch).toList();
    final range = pitches.reduce(math.max) - pitches.reduce(math.min);
    final rangeScore = range >= 5 && range <= 22 ? 1.0 : (range < 5 ? 0.3 : 0.6);
    final variety =
        (pitches.toSet().length / 5.0).clamp(0.0, 1.0); // >=5 distinct pitches

    return ((0.45 * stepScore + 0.3 * rangeScore + 0.25 * variety) *
            (1.0 - 0.5 * leapPenalty) *
            (1.0 - repeatPenalty))
        .clamp(0.0, 1.0);
  }

  // ---- consonant: lead vs bass on strong beats ------------------------------

  double _consonant(Composition c) {
    var good = 0, total = 0;
    for (final p in c.patterns) {
      final lead = _voice(p, 'lead');
      final bass = _voice(p, 'bass');
      if (lead.isEmpty || bass.isEmpty) continue;
      final len = _len(p);
      for (var beat = 0.0; beat < len; beat += 2.0) {
        final l = _soundingAt(lead, beat);
        final b = _soundingAt(bass, beat);
        if (l == null || b == null) continue;
        total++;
        const consonantIvs = {0, 3, 4, 5, 7, 8, 9};
        if (consonantIvs.contains((l.pitch - b.pitch) % 12)) good++;
      }
    }
    if (total < 4) return 0.4;
    // Real themes sit ~70-95% consonant on strong beats; below that = clash.
    return ((good / total - 0.45) / 0.4).clamp(0.0, 1.0);
  }

  // ---- groove: one drum pattern kept + bass locked to the kick --------------

  double _groove(Composition c, Map<Pattern, List<Note>> drumBars) {
    var similarity = 0.0;
    var n = 0;
    for (final e in drumBars.entries) {
      final len = _len(e.key);
      final bars = (len / 4).floor();
      if (bars < 2 || e.value.length < 4) continue;
      // Compare each bar's onset grid with bar 0 (skip the last bar — fills
      // are legitimate there).
      final ref = _onsetGrid(e.value, 0, 4);
      if (ref.isEmpty) continue;
      var s = 0.0;
      var m = 0;
      for (var bar = 1; bar < bars - 1; bar++) {
        final g = _onsetGrid(e.value, bar * 4.0, bar * 4.0 + 4);
        s += _gridSimilarity(ref, g);
        m++;
      }
      if (m > 0) {
        similarity += s / m;
        n++;
      }
    }
    final steady = n == 0 ? 0.4 : similarity / n;

    // Bass onsets should coincide with kick onsets.
    var lock = 0.0;
    var lp = 0;
    for (final p in c.patterns) {
      final bass = _voice(p, 'bass');
      final kicks = _voice(p, 'drums')
          .where((d) => d.pitch == 35 || d.pitch == 36)
          .toList();
      if (bass.isEmpty || kicks.isEmpty) continue;
      var hit = 0;
      for (final k in kicks) {
        if (bass.any((b) => (b.start - k.start).abs() < 0.13)) hit++;
      }
      lock += hit / kicks.length;
      lp++;
    }
    final lockScore = lp == 0 ? 0.4 : lock / lp;
    return 0.6 * steady + 0.4 * lockScore;
  }

  // ---- breathing: density sweet spot + rests --------------------------------

  double _breathing(Map<Pattern, List<Note>> leadBars) {
    var score = 0.0;
    var n = 0;
    for (final e in leadBars.entries) {
      final len = _len(e.key);
      if (len <= 0 || e.value.isEmpty) continue;
      final perBar = e.value.length / (len / 4);
      final density = perBar >= 2.5 && perBar <= 9
          ? 1.0
          : perBar < 2.5
              ? perBar / 2.5
              : (14 - perBar).clamp(0.0, 5.0) / 5.0;
      final sounding =
          e.value.fold(0.0, (a, x) => a + x.duration).clamp(0.0, len);
      final coverage = sounding / len;
      final rests = coverage < 0.93 ? 1.0 : 0.4; // phrases must breathe
      score += 0.7 * density + 0.3 * rests;
      n++;
    }
    return n == 0 ? 0.3 : score / n;
  }

  // ---- dynamics: the chorus lifts over the verse -----------------------------

  double _dynamics(Composition c) {
    double? verse, chorus;
    for (final p in c.patterns) {
      final id = p.id.toLowerCase();
      final lead = _voice(p, 'lead');
      if (lead.isEmpty) continue;
      final avg = lead.map((n) => n.pitch).fold(0, (a, b) => a + b) / lead.length;
      if (id.contains('chorus')) {
        chorus = math.max(chorus ?? avg, avg);
      } else if (id.contains('verse')) {
        verse = verse ?? avg;
      }
    }
    if (verse == null || chorus == null) return 0.5;
    return chorus >= verse + 1 ? 1.0 : (chorus >= verse ? 0.7 : 0.3);
  }

  // ---- helpers ---------------------------------------------------------------

  Map<Pattern, List<Note>> _bars(Composition c, String voice) => {
        for (final p in c.patterns)
          if (_voice(p, voice).isNotEmpty) p: _voice(p, voice),
      };

  List<Note> _voice(Pattern p, String id) {
    for (final t in p.tracks) {
      if (t.instrumentId == id) {
        return t.notes.where((n) => !n.isRest).toList();
      }
    }
    return const [];
  }

  double _len(Pattern p) {
    if (p.lengthBeats > 0) return p.lengthBeats;
    var end = 0.0;
    for (final t in p.tracks) {
      for (final n in t.notes) {
        end = math.max(end, n.start + n.duration);
      }
    }
    return end;
  }

  Note? _soundingAt(List<Note> notes, double beat) {
    for (final n in notes) {
      if (n.start <= beat + 1e-6 && n.start + n.duration > beat + 0.05) {
        return n;
      }
    }
    return null;
  }

  /// Quantized onset pattern + contour signs for a beat window (motif shape).
  List<int> _rhythmContour(List<Note> notes, double lo, double hi) {
    final win = notes
        .where((n) => n.start >= lo - 1e-6 && n.start < hi - 1e-6)
        .toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    final out = <int>[];
    for (var i = 0; i < win.length; i++) {
      final q = ((win[i].start - lo) * 4).round(); // 16th grid position
      final dir = i == 0 ? 0 : (win[i].pitch - win[i - 1].pitch).sign;
      out.add(q * 4 + (dir + 1)); // pack position+direction into one symbol
    }
    return out;
  }

  double _similarity(List<int> a, List<int> b) {
    if (a.isEmpty || b.isEmpty) return 0;
    final sa = a.toSet(), sb = b.toSet();
    final inter = sa.intersection(sb).length;
    final union = sa.union(sb).length;
    return union == 0 ? 0 : inter / union;
  }

  Set<int> _onsetGrid(List<Note> notes, double lo, double hi) => {
        for (final n in notes)
          if (n.start >= lo - 1e-6 && n.start < hi - 1e-6)
            ((n.start - lo) * 4).round(),
      };

  double _gridSimilarity(Set<int> a, Set<int> b) {
    if (a.isEmpty && b.isEmpty) return 1;
    final union = a.union(b).length;
    return union == 0 ? 1 : a.intersection(b).length / union;
  }
}
