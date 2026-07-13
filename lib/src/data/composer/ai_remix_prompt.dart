import 'dart:convert';

import '../../domain/entities/composition.dart';
import '../../domain/entities/instrument.dart';
import '../../domain/entities/note.dart';
import '../../domain/entities/pattern.dart';

/// Builds a short, human-sounding clipboard prompt for an external AI chat.
/// Includes tiny real "hit phrases" from the RAG library so the model hears
/// craft — without dumping a whole song (chat UIs stay snappy).
class AiRemixPrompt {
  const AiRemixPrompt();

  /// Soft size budget for the whole prompt (chars).
  static const maxChars = 6500;

  String build(
    Composition c, {
    List<Map<String, dynamic>> hits = const [],
  }) {
    final vibe = _vibeLine(c);
    final skeleton = _skeleton(c);
    final hitBlock = _hitsBlock(hits);

    String pack({required bool withHits, required bool withSeed}) {
      final sk = Map<String, dynamic>.from(skeleton);
      if (!withSeed) sk.remove('hook');
      return '${_voice(vibe)}'
          '${withHits ? hitBlock : ''}'
          '${_schema()}'
          'YOUR STARTING POINT — the track on the turntable right now '
          '(steal the mood & energy, invent NEW notes):\n'
          '${const JsonEncoder().convert(sk)}\n\n'
          'Go write the song. JSON only.';
    }

    var out = pack(withHits: hits.isNotEmpty, withSeed: true);
    if (out.length > maxChars && hits.isNotEmpty) {
      out = pack(withHits: false, withSeed: true);
    }
    if (out.length > maxChars) {
      out = pack(withHits: false, withSeed: false);
    }
    return out;
  }

  String _voice(String vibe) => '''
Hey — I need you to write me a ChipMood chiptune. Not a sterile MIDI dump:
something that feels like a real game OST hook. Think NES / SNES / demoscene
energy — a melody you can hum after one listen.

$vibe

You're writing a *song plan* the ChipMood app will arrange & synthesize.
Reply with ONLY one JSON object. No markdown fences, no "sure!", no essay.

THE CONTRACT (break these and the app turns your song into mush):
1. ONE key. Pick root + scale, then EVERY lead/harmony/counter/bass pitch must
   belong to that scale. The app force-snaps stray notes and that mangles lines.
2. "chords" are SCALE DEGREES 0-6 (0 = tonic), exactly one per bar. The app
   builds extra accompaniment (pads, arps) FROM these numbers — if they don't
   match what your melody is doing, the layers fight and it sounds random.
3. MOTIF, not noodling. Per section write a 2-bar motif; bars 3-4 = the SAME
   motif with only the ending changed. The chorus hook is sacred: every chorus
   section restates it (transpose +2 in chorusFinal is fine). Repetition is
   what makes it a composition.
4. Grid: quantize every start & duration to 0.25 beats. Voices are monophonic —
   no overlaps within one voice. Leave rests; a phrase must breathe.

Craft (from real pro tracks):
- Lead: chord tone of the CURRENT bar's degree on beats 0 and 2, stepwise
  motion between, 4-8 notes/bar. Verses sit close; choruses leap and go higher.
- Harmony: 2-4 LONG chord tones per bar (a bed, not a second melody).
- Counter: chorus only, echoes the lead a third/sixth below.
- Bass: roots & fifths of the bar's chord, locked to the kick, 2-4 notes/bar.
- Drums: kick 36, snare 38, tom 40, hat 42. Pick ONE groove and keep it every
  bar; earn the fill in each section's last bar.
- Form: intro sparse (no lead ok) → verse → chorus → verse → chorus → bridge
  (new chords, same key) → chorusFinal → outro. Reuse section ids in the
  arrangement — hearing material return IS the song.
- Keep it SMALL: 4 bars per section. Chat-friendly.

''';

  String _hitsBlock(List<Map<String, dynamic>> hits) {
    if (hits.isEmpty) return '';
    final buf = StringBuffer(
      'REAL HIT PHRASES (1 bar each, from professional game music). Notice: '
      'few pitches, strong beats land on chord tones, bass stays simple, the '
      'drums repeat. Study the rhythm & contour, then write YOUR own:\n',
    );
    for (var i = 0; i < hits.length; i++) {
      final h = hits[i];
      buf.writeln(
        'Hit ${i + 1} · ${h['mood']} · ${h['bpm']}bpm · ${h['scale']}'
        '${h['timbre'] != null ? ' · ${h['timbre']}' : ''}'
        ' · ${h['from']}:',
      );
      buf.writeln(const JsonEncoder().convert({
        if (h['chord'] != null) 'chord': h['chord'],
        'lead': h['lead'],
        if (h['bass'] != null) 'bass': h['bass'],
        if (h['drums'] != null) 'drums': h['drums'],
      }));
    }
    buf.writeln();
    return buf.toString();
  }

  String _schema() => '''
JSON shape:
{
  "title": "evocative name",
  "bpm": 70-190,
  "root": 57-64,
  "scale": "major"|"minor"|"dorian"|"mixolydian"|"phrygian"|"harmonicminor",
  "timbre": "square"|"saw"|"brass"|"string"|"organ"|"reed"|"mellow"|"bright",
  "production": {  // all optional, 0..1 — set only what the song needs
    "leadDrive","leadCrush","leadGlide","bassDrive","drumsTone",
    "percTone","padTrem","arpTrem","cutoff","resonance","filterEnv","delay"
  },
  "sections": [
    {
      "id": "intro"|"verseA"|"chorus"|"bridge"|"chorusFinal"|"outro"|...,
      "bars": 4,
      "energy": 0.3-1.0,   // arrangement density, NOT volume
      "chords": [0,4,5,3], // scale degrees 0-6, ONE PER BAR — must fit the melody
      "lead":    [[start,pitch,dur,vel], ...],
      "harmony": [[start,pitch,dur,vel], ...],
      "counter": [[start,pitch,dur,vel], ...],
      "bass":    [[start,pitch,dur,vel], ...],
      "drums":   [[start,pitch,dur,vel], ...]
    }
  ],
  "arrangement": ["intro","verseA","chorus","verseA","chorus","bridge","chorusFinal","outro"]
}

Notes are [startBeat, midiPitch, durationBeats, velocity0to1]; starts are
0..(bars*4) within the section; quantize to 0.25. Lead ~48-84, bass ~28-52.
bass+drums in every bar. 4-7 sections, arrangement ~8-14 ids (repeat them!).

Before you answer, self-check: same key everywhere? chords match the melody
bar by bar? every section's bars 3-4 restate bars 1-2? drums keep one groove?

''';

  String _vibeLine(Composition c) {
    final bpm = c.bpm.round();
    String energy;
    if (bpm >= 155) {
      energy = 'This one wants to race — boss-rush / arcade heat.';
    } else if (bpm >= 130) {
      energy = 'Mid-tempo drive — overworld adventure energy.';
    } else if (bpm >= 100) {
      energy = 'A walking pulse — town theme / soft resolve.';
    } else {
      energy = 'Slow and heavy — nostalgic, almost bittersweet.';
    }
    final title = c.title.trim().isEmpty ? 'Untitled' : c.title.trim();
    return 'The track on the deck is "$title" @ ${bpm}bpm (~${c.targetSeconds.round()}s). $energy';
  }

  Map<String, dynamic> _skeleton(Composition c) {
    final patterns = <Map<String, dynamic>>[];
    for (final p in c.patterns.take(7)) {
      patterns.add({
        'id': p.id,
        'bars': (p.lengthBeats / 4).round().clamp(1, 8),
        'voices': {
          for (final t in p.tracks)
            if (t.notes.isNotEmpty)
              t.instrumentId: t.notes.where((n) => !n.isRest).length,
        },
      });
    }

    final hook = _leadSeed(c);
    return {
      'title': c.title,
      'bpm': c.bpm.round(),
      'seconds': c.targetSeconds.round(),
      'delay': double.parse(c.delayWet.toStringAsFixed(2)),
      'sound': [for (final i in c.instruments) _instLine(i)],
      'form': c.arrangement.take(14).toList(),
      'sections': patterns,
      if (hook.isNotEmpty) 'hook': hook,
    };
  }

  String _instLine(Instrument i) {
    final parts = <String>[
      i.id,
      i.waveform.wire,
      if (i.duty != 0.5) 'd${_r(i.duty)}',
      'v${_r(i.volume)}',
      if (i.drive > 0.05) 'drv${_r(i.drive)}',
      if (i.cutoff < 0.95) 'cut${_r(i.cutoff)}',
      if (i.crush > 0.05) 'cr${_r(i.crush)}',
      if (i.tone != 0.5 && (i.id == 'drums' || i.id == 'perc'))
        'tone${_r(i.tone)}',
    ];
    return parts.join(':');
  }

  List<List<num>> _leadSeed(Composition c) {
    Pattern? best;
    var bestN = 0;
    for (final p in c.patterns) {
      final id = p.id.toLowerCase();
      final prefer = id.contains('chorus') || id.contains('verse') ? 2 : 1;
      final lead = p.tracks
          .where((t) => t.instrumentId == 'lead')
          .expand((t) => t.notes)
          .where((n) => !n.isRest)
          .toList();
      final score = lead.length * prefer;
      if (score > bestN) {
        bestN = score;
        best = p;
      }
    }
    if (best == null) return const [];
    return best.tracks
        .where((t) => t.instrumentId == 'lead')
        .expand((t) => t.notes)
        .where((n) => !n.isRest)
        .take(8)
        .map(_compactNote)
        .toList();
  }

  List<num> _compactNote(Note n) {
    return [
      _q(n.start),
      n.pitch,
      _q(n.duration),
      double.parse(n.velocity.toStringAsFixed(2)),
    ];
  }

  static double _q(double v) => (v * 4).round() / 4.0;
  static String _r(double v) => v.toStringAsFixed(2);
}
