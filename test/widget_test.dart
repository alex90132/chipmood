// Unit tests for the pure domain logic. These run without a device and do not
// touch the Rust bridge or platform plugins.

import 'package:flutter_test/flutter_test.dart';

import 'package:chiptune_ai/src/data/mappers/composition_mapper.dart';
import 'package:chiptune_ai/src/domain/entities/waveform.dart';

void main() {
  const mapper = CompositionMapper();

  Map<String, dynamic> sampleSong() => {
        'title': 'Test Song',
        'bpm': 150,
        'instruments': [
          {'id': 'lead', 'waveform': 'pulse', 'duty': 0.5},
          {'id': 'bass', 'waveform': 'triangle'},
          {'id': 'drums', 'waveform': 'noise'},
        ],
        'patterns': [
          {
            'id': 'A',
            'length_beats': 16,
            'tracks': [
              {
                'instrument': 'lead',
                'notes': [
                  {'pitch': 72, 'start': 0, 'duration': 1},
                  {'pitch': -1, 'start': 1, 'duration': 1},
                  {'pitch': 76, 'start': 2, 'duration': 1},
                ],
              },
              {
                'instrument': 'bass',
                'notes': [
                  {'pitch': 36, 'start': 0, 'duration': 2},
                ],
              },
            ],
          },
        ],
        'arrangement': ['A', 'A'],
      };

  test('parses a tracker-style song JSON', () {
    final comp = mapper.fromJson(sampleSong(), targetSeconds: 90);

    expect(comp.title, 'Test Song');
    expect(comp.bpm, 150);
    expect(comp.targetSeconds, 90);
    expect(comp.instrumentCount, 3);
    expect(comp.patternCount, 1);
    expect(comp.sectionCount, 2); // arrangement length
    expect(comp.instruments.first.waveform, Waveform.pulse);
    expect(comp.noteCount, 3); // rest excluded
  });

  test('round-trips a song through JSON without losing structure', () {
    final comp = mapper.fromJson(sampleSong());
    final back = mapper.fromJson(mapper.toJson(comp));

    expect(back.instrumentCount, 3);
    expect(back.patternCount, 1);
    expect(back.arrangement, ['A', 'A']);
    expect(back.patterns.first.tracks.length, 2);
  });

  test('falls back to defaults for malformed values', () {
    final comp = mapper.fromJson({'bpm': 'nope', 'instruments': []});
    expect(comp.bpm, 120);
    expect(comp.instruments, isEmpty);
    expect(comp.patterns, isEmpty);
  });
}
