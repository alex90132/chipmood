import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:chiptune_ai/src/data/arranger/procedural_arranger.dart';
import 'package:chiptune_ai/src/data/critic/hit_critic.dart';
import 'package:chiptune_ai/src/data/knowledge/groove_library.dart';
import 'package:chiptune_ai/src/domain/entities/composition.dart';
import 'package:chiptune_ai/src/domain/entities/note.dart';
import 'package:chiptune_ai/src/domain/entities/pattern.dart';

void main() {
  const critic = HitCritic();

  Pattern hitPattern(String id, {int lift = 0}) {
    // A 4-bar section built like a real theme: a 2-bar motif restated in bars
    // 3-4 with a changed ending, consonant bass, one drum groove throughout.
    final lead = <Note>[];
    for (final barPair in [0.0, 8.0]) {
      lead.addAll([
        Note(pitch: 72 + lift, start: barPair + 0.0, duration: 1.0, velocity: .9),
        Note(pitch: 74 + lift, start: barPair + 1.0, duration: 0.5, velocity: .8),
        Note(pitch: 75 + lift, start: barPair + 1.5, duration: 1.5, velocity: .9),
        Note(pitch: 74 + lift, start: barPair + 4.0, duration: 1.0, velocity: .85),
        Note(pitch: 72 + lift, start: barPair + 5.0, duration: 0.5, velocity: .8),
        // bars 3-4 restate the motif; only this ending differs
        Note(
            pitch: (barPair == 0.0 ? 79 : 84) + lift,
            start: barPair + 5.5,
            duration: 1.5,
            velocity: .95),
      ]);
    }
    final bass = <Note>[
      for (var bar = 0; bar < 4; bar++) ...[
        Note(pitch: 36, start: bar * 4.0, duration: 1.5, velocity: .9),
        Note(pitch: 43, start: bar * 4.0 + 2.0, duration: 1.5, velocity: .85),
      ],
    ];
    final drums = <Note>[
      for (var bar = 0; bar < 4; bar++) ...[
        Note(pitch: 36, start: bar * 4.0, duration: 0.2, velocity: .95),
        Note(pitch: 42, start: bar * 4.0 + 0.5, duration: 0.1, velocity: .5),
        Note(pitch: 38, start: bar * 4.0 + 1.0, duration: 0.15, velocity: .85),
        Note(pitch: 42, start: bar * 4.0 + 1.5, duration: 0.1, velocity: .5),
        Note(pitch: 36, start: bar * 4.0 + 2.0, duration: 0.2, velocity: .9),
        Note(pitch: 42, start: bar * 4.0 + 2.5, duration: 0.1, velocity: .5),
        Note(pitch: 38, start: bar * 4.0 + 3.0, duration: 0.15, velocity: .85),
        Note(pitch: 42, start: bar * 4.0 + 3.5, duration: 0.1, velocity: .5),
      ],
    ];
    return Pattern(id: id, lengthBeats: 16, tracks: [
      PatternTrack(instrumentId: 'lead', notes: lead),
      PatternTrack(instrumentId: 'bass', notes: bass),
      PatternTrack(instrumentId: 'drums', notes: drums),
    ]);
  }

  Pattern mushPattern(String id, Random r) {
    // Anti-music: chromatic random pitches, random onsets, wall-to-wall notes,
    // a different drum pattern every bar.
    final lead = <Note>[];
    var t = 0.0;
    while (t < 15.5) {
      lead.add(Note(
          pitch: 48 + r.nextInt(36),
          start: t,
          duration: 0.5,
          velocity: .9));
      t += 0.5;
    }
    final bass = <Note>[
      for (var i = 0; i < 16; i++)
        Note(
            pitch: 28 + r.nextInt(24),
            start: i * 1.0 + r.nextDouble() * 0.4,
            duration: 0.5,
            velocity: .9),
    ];
    final drums = <Note>[
      for (var i = 0; i < 24; i++)
        Note(
            pitch: 35 + r.nextInt(16),
            start: r.nextDouble() * 16,
            duration: 0.1,
            velocity: .8),
    ];
    return Pattern(id: id, lengthBeats: 16, tracks: [
      PatternTrack(instrumentId: 'lead', notes: lead),
      PatternTrack(instrumentId: 'bass', notes: bass),
      PatternTrack(instrumentId: 'drums', notes: drums),
    ]);
  }

  test('critic ranks a crafted theme far above random mush', () {
    final hit = Composition(
      title: 'Hit',
      bpm: 130,
      patterns: [
        hitPattern('verse'),
        hitPattern('chorus', lift: 3),
      ],
      arrangement: ['verse', 'chorus', 'verse', 'chorus', 'chorus'],
    );
    final r = Random(7);
    final mush = Composition(
      title: 'Mush',
      bpm: 130,
      patterns: [mushPattern('a', r), mushPattern('b', r)],
      arrangement: ['a', 'b'],
    );
    final hitScore = critic.score(hit);
    final mushScore = critic.score(mush);
    expect(hitScore, greaterThan(0.65),
        reason: 'crafted theme under-scored: ${critic.breakdown(hit)}');
    expect(mushScore, lessThan(0.45),
        reason: 'mush over-scored: ${critic.breakdown(mush)}');
    expect(hitScore - mushScore, greaterThan(0.3));
  });

  test('critic discriminates between real arranger outputs (best-of works)',
      () {
    final raw = File('assets/rag/grooves.json').readAsStringSync();
    final m = jsonDecode(raw) as Map<String, dynamic>;
    List<List<double>> rows(dynamic v) => (v as List)
        .map<List<double>>(
            (n) => (n as List).map((x) => (x as num).toDouble()).toList())
        .toList();
    final grooves = GrooveData(
      ((m['fills'] as List?) ?? const []).map(rows).toList(),
      ((m['voicings'] as List?) ?? const [])
          .map<List<int>>(
              (v) => (v as List).map((x) => (x as num).toInt()).toList())
          .where((v) => v.length >= 3)
          .toList(),
      ((m['grooves'] as List?) ?? const [])
          .map<GrooveBeat>((g) => GrooveBeat(
              rows((g as Map)['p']), (g['tone'] as num?)?.toDouble() ?? 0.5))
          .where((g) => g.notes.isNotEmpty)
          .toList(),
      ((m['basslines'] as List?) ?? const []).map(rows).toList(),
      ((m['harmonies'] as List?) ?? const []).map(rows).toList(),
      ((m['arps'] as List?) ?? const []).map(rows).toList(),
      ((m['melodies'] as List?) ?? const []).map(rows).toList(),
      ((m['profiles'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList(),
    );
    const arranger = ProceduralArranger();
    final scores = <double>[];
    for (var i = 1; i <= 15; i++) {
      final c = arranger.build({
        'title': 'Take $i',
        'bpm': 140,
        'root': 60,
        'scale': 'minor',
        'seed': i * 7919,
        'sections': [
          {'id': 'verse', 'bars': 4, 'energy': 0.7, 'chords': [0, 5, 3, 4]},
          {'id': 'chorus', 'bars': 4, 'energy': 1.0, 'chords': [3, 4, 0, 5]},
        ],
        'arrangement': ['verse', 'chorus', 'verse', 'chorus'],
      }, grooves: grooves);
      scores.add(critic.score(c));
    }
    final lo = scores.reduce(min), hi = scores.reduce(max);
    // If every take got the same score the critic can't pick a winner.
    expect(hi - lo, greaterThan(0.02),
        reason: 'critic gives one flat score: $scores');
    // And arranger output should generally land in a sane band.
    expect(hi, greaterThan(0.5));
  });
}
