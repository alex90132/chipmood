import 'package:flutter_test/flutter_test.dart';

import 'package:chiptune_ai/src/data/arranger/procedural_arranger.dart';
import 'package:chiptune_ai/src/data/composer/ai_remix_prompt.dart';

void main() {
  test('human prompt includes hit phrases and stays chat-sized', () {
    final c = const ProceduralArranger().build({
      'title': 'Neon Cascade',
      'bpm': 140,
      'root': 60,
      'scale': 'minor',
      'seed': 42,
      'sections': [
        {
          'id': 'chorus',
          'bars': 4,
          'energy': 1.0,
          'chords': [0, 5, 3, 4]
        },
      ],
      'arrangement': ['chorus'],
    }, targetSeconds: 154);

    final hits = [
      {
        'mood': 'happy',
        'bpm': 136,
        'scale': 'major',
        'from': 'ut',
        'chord': 0,
        'lead': [
          [0.0, 72, 0.5, 0.9],
          [0.5, 74, 0.5, 0.85],
          [1.0, 76, 1.0, 0.95],
          [2.0, 79, 1.0, 1.0],
        ],
        'bass': [
          [0.0, 48, 1.0, 0.8],
          [1.0, 55, 1.0, 0.75],
        ],
        'drums': [
          [0.0, 36, 0.2, 0.95],
          [1.0, 38, 0.15, 0.85],
        ],
      },
    ];

    final prompt = const AiRemixPrompt().build(c, hits: hits);
    expect(prompt.length, lessThan(AiRemixPrompt.maxChars));
    expect(prompt, contains('Hey —'));
    expect(prompt, contains('REAL HIT PHRASES'));
    expect(prompt, contains('ut'));
    expect(prompt, contains('Neon Cascade'));
    expect(prompt, contains('JSON only'));
    expect(prompt, isNot(contains('"patterns"')));
  });
}
