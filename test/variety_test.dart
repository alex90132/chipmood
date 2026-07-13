import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chiptune_ai/src/data/arranger/procedural_arranger.dart';
import 'package:chiptune_ai/src/data/knowledge/groove_library.dart';

/// Regression tests for "all tracks sound the same": with the real mined
/// groove/profile data loaded, different generations must land on genuinely
/// different timbres, effects and grooves.
void main() {
  const arranger = ProceduralArranger();

  GrooveData loadGrooves() {
    final raw = File('assets/rag/grooves.json').readAsStringSync();
    final m = jsonDecode(raw) as Map<String, dynamic>;
    List<List<double>> rows(dynamic v) => (v as List)
        .map<List<double>>(
            (n) => (n as List).map((x) => (x as num).toDouble()).toList())
        .toList();
    return GrooveData(
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
  }

  Map<String, dynamic> plan(int seed) => {
        'title': 'Test',
        'bpm': 140,
        'root': 60,
        'scale': 'minor',
        'seed': seed,
        'sections': [
          {'id': 'chorus', 'bars': 4, 'energy': 1.0, 'chords': [0, 5, 3, 4]},
        ],
        'arrangement': ['chorus'],
      };

  test('different seeds give different timbres/effects/grooves', () {
    final grooves = loadGrooves();
    const n = 40;
    final soundIds = <String>{};
    final drumTones = <double>{};
    final cutoffs = <double>{};
    final drumRhythms = <String>{};
    for (var i = 1; i <= n; i++) {
      final c = arranger.build(plan(i * 7919), grooves: grooves);
      final fp = c.instruments
          .map((inst) => '${inst.id}:${inst.waveform.name}:'
              '${inst.duty.toStringAsFixed(2)}:'
              '${inst.drive.toStringAsFixed(2)}:'
              '${inst.cutoff.toStringAsFixed(2)}:'
              '${inst.tone.toStringAsFixed(2)}')
          .join('|');
      soundIds.add(fp);
      final drums = c.instruments.firstWhere((x) => x.id == 'drums');
      drumTones.add((drums.tone * 20).roundToDouble());
      final lead = c.instruments.firstWhere((x) => x.id == 'lead');
      cutoffs.add((lead.cutoff * 20).roundToDouble());
      drumRhythms.add(c.patterns.first.tracks
          .firstWhere((t) => t.instrumentId == 'drums')
          .notes
          .map((x) => x.start.toStringAsFixed(1))
          .join(','));
    }
    // Every generation must have its own overall sound fingerprint.
    expect(soundIds.length, n,
        reason: 'instrument fingerprints collided between generations');
    // And the individual knobs must actually spread, not sit on one value.
    expect(drumTones.length, greaterThanOrEqualTo(8),
        reason: 'drum tone barely varies');
    expect(cutoffs.length, greaterThanOrEqualTo(6),
        reason: 'lead filter cutoff barely varies');
    expect(drumRhythms.length, greaterThanOrEqualTo(n ~/ 2),
        reason: 'drum grooves repeat too much');
  });

  test('a dataset timbre tag no longer stamps the same lead on every track',
      () {
    // Most exemplars are tagged 'bright'; it used to hard-map every lead to
    // pulse 0.25. Now it is only a bias, so leads must still vary.
    final grooves = loadGrooves();
    final leads = <String>{};
    for (var i = 1; i <= 30; i++) {
      final p = plan(i * 104729)..['timbre'] = 'bright';
      final c = arranger.build(p, grooves: grooves);
      final lead = c.instruments.firstWhere((x) => x.id == 'lead');
      leads.add('${lead.waveform.name}:${lead.duty.toStringAsFixed(2)}');
    }
    expect(leads.length, greaterThanOrEqualTo(10),
        reason: 'timbre tag still forces one lead sound: $leads');
  });

  test('an authored (AI-pasted) section keeps its melody, drums and fill', () {
    final grooves = loadGrooves();
    // A fully-voiced plan like the AI remix prompt asks for: motif-based lead,
    // kit drums locked to the bass. None of it may be replaced or overwritten.
    final lead = <List<num>>[
      for (var bar = 0; bar < 4; bar++) ...[
        [bar * 4.0, 72, 0.5, 0.9],
        [bar * 4.0 + 0.5, 74, 0.5, 0.85],
        [bar * 4.0 + 1.0, 75, 1.0, 0.9],
        [bar * 4.0 + 2.5, 79, 1.0, 0.95],
      ],
    ];
    final drums = <List<num>>[
      for (var bar = 0; bar < 4; bar++) ...[
        [bar * 4.0, 36, 0.2, 0.95],
        [bar * 4.0 + 1.0, 38, 0.15, 0.85],
        [bar * 4.0 + 2.0, 36, 0.2, 0.9],
        [bar * 4.0 + 3.0, 38, 0.15, 0.85],
      ],
    ];
    final p = {
      'title': 'Authored',
      'bpm': 128,
      'root': 60,
      'scale': 'minor',
      'seed': 99,
      'sections': [
        {
          'id': 'verseA',
          'bars': 4,
          'energy': 0.8,
          'chords': [0, 5, 3, 4],
          'lead': lead,
          'harmony': [
            for (var bar = 0; bar < 4; bar++) [bar * 4.0, 60, 3.5, 0.6],
          ],
          'bass': [
            for (var bar = 0; bar < 4; bar++) ...[
              [bar * 4.0, 36, 1.0, 0.9],
              [bar * 4.0 + 2.0, 43, 1.0, 0.85],
            ],
          ],
          'drums': drums,
        },
      ],
      'arrangement': ['verseA'],
    };
    final c = arranger.build(p, grooves: grooves);
    final tracks = {
      for (final t in c.patterns.first.tracks) t.instrumentId: t.notes
    };
    // Drums: exactly the authored groove — no RAG groove swap, no extra fill.
    expect(tracks['drums']!.length, drums.length,
        reason: 'authored kit drums were replaced or a fill was stacked');
    // Lead: the authored phrase ending survives (no injected pickup run).
    expect(tracks['lead']!.length, lead.length,
        reason: 'authored lead was rewritten');
    expect(tracks['lead']!.last.pitch, 79);
  });

  test('same plan (same seed) still reproduces the identical track', () {
    final grooves = loadGrooves();
    final a = arranger.build(plan(123456), grooves: grooves);
    final b = arranger.build(plan(123456), grooves: grooves);
    for (var i = 0; i < a.instruments.length; i++) {
      expect(a.instruments[i].waveform, b.instruments[i].waveform);
      expect(a.instruments[i].drive, b.instruments[i].drive);
      expect(a.instruments[i].cutoff, b.instruments[i].cutoff);
      expect(a.instruments[i].tone, b.instruments[i].tone);
    }
    final la = a.patterns.first.tracks.first.notes;
    final lb = b.patterns.first.tracks.first.notes;
    expect(la.length, lb.length);
    for (var i = 0; i < la.length; i++) {
      expect(la[i].pitch, lb[i].pitch);
      expect(la[i].start, lb[i].start);
    }
  });
}
