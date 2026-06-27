/// Curated "track DNA" used as RAG context for the composer.
///
/// It encodes the STRUCTURE of proven hits / classic game music — keys, tempos,
/// chord progressions (as scale degrees), song forms and groove notes by mood —
/// plus a couple of full worked "song plan" exemplars in our exact JSON format.
/// Only non-copyrightable structure is encoded; the melodies in the exemplars
/// are original. The model studies these and composes something original in the
/// matching style.
library;

/// Mood -> proven recipe. Degrees are 0=tonic..6, interpreted in the listed
/// scale (so [0,5,2,6] in minor = i-VI-III-VII).
const String kMoodGuide = '''
MOOD RECIPES (pick the one matching the photo, then write your own in that style):
- HEROIC / ADVENTURE / OVERWORLD: scale major or mixolydian, BPM 124-142.
  Progressions: I-V-vi-IV [0,4,5,3] or I-IV-vi-V [0,3,5,4] or vi-IV-I-V [5,3,0,4].
  Lead: bright, bouncy, dotted/swing rhythms, confident leaps. (e.g. Mario/Zelda overworld feel)
- EPIC BOSS / BATTLE / INTENSE: scale minor or phrygian, BPM 150-180.
  Progressions: i-bVI-bVII [0,5,6], i-bVII-bVI-V (minor) [0,6,5,4], or phrygian i-bII [0,1].
  Lead: fast 16th runs, aggressive, chromatic tension, driving bass. (boss-fight energy)
- PEACEFUL / TOWN / CALM: scale major, BPM 92-116.
  Progressions: I-vi-IV-V [0,5,3,4], IV-I-V-vi [3,0,4,5], I-iii-IV-V [0,2,3,4].
  Lead: gentle, flowing, legato, fewer notes, warm.
- SAD / NOSTALGIC / EMOTIONAL: scale minor, BPM 76-104.
  Progressions: i-VI-III-VII [0,5,2,6], vi-IV-I-V [5,3,0,4], i-iv-VII-III [0,3,6,2].
  Lead: expressive, space and rests, longing upward leaps then fall.
- MYSTERIOUS / DUNGEON / DARK: scale harmonicminor or phrygian, BPM 100-128.
  Progressions: i-iv-i-V [0,3,0,4], i-bII-i [0,1,0], i-v-VI [0,4,5].
  Lead: sparse, suspenseful, narrow range, unresolved.
- UPBEAT / DANCE / VICTORY: scale major, BPM 138-168.
  Progressions: I-V-vi-IV [0,4,5,3], I-IV-V-IV [0,3,4,3].
  Lead: syncopated, catchy, repeated rhythmic hook.

UNIVERSAL HIT FORM: intro(sparse) -> verseA -> preChorus(build, end on V=4) ->
chorus(the hook, highest energy) -> verseB -> chorus -> bridge(contrast) ->
chorusFinal(climax, +2 lift) -> outro. Reuse one progression so it feels unified.
''';

/// A full original "song plan" in our exact schema — a heroic/adventure track
/// in C major (I-V-vi-IV). The model studies the FORMAT and density here.
const String _exemplarHeroic = '''
{"title":"Skyward Trail","bpm":136,"root":60,"scale":"major",
 "sections":[
  {"id":"intro","bars":4,"energy":0.5,"chords":[0,4,5,3],"lead":[[0,67,1,0.7],[2,72,1,0.7],[3,71,1,0.7]]},
  {"id":"verseA","bars":4,"energy":0.7,"chords":[0,4,5,3],"lead":[[0,67,0.5,0.85],[0.5,69,0.5,0.8],[1,72,1,0.9],[2,71,0.5,0.8],[2.5,69,0.5,0.8],[3,67,1,0.8]]},
  {"id":"preChorus","bars":4,"energy":0.85,"chords":[5,3,0,4],"lead":[[0,69,0.5,0.85],[0.5,71,0.5,0.85],[1,72,0.5,0.9],[1.5,74,0.5,0.9],[2,76,1,0.95],[3,79,1,1]]},
  {"id":"chorus","bars":4,"energy":1.0,"chords":[0,4,5,3],"lead":[[0,79,1,1],[1,76,0.5,0.95],[1.5,77,0.5,0.95],[2,79,1,1],[3,72,0.5,0.9],[3.5,74,0.5,0.9]]},
  {"id":"bridge","bars":4,"energy":0.8,"chords":[3,0,3,4],"lead":[[0,74,0.75,0.85],[0.75,72,0.75,0.85],[1.5,71,1,0.85],[2.5,69,1.5,0.8]]},
  {"id":"chorusFinal","bars":4,"energy":1.0,"chords":[0,4,5,3],"lead":[[0,79,1,1],[1,76,0.5,0.95],[1.5,77,0.5,0.95],[2,79,1,1],[3,84,1,1]]},
  {"id":"outro","bars":2,"energy":0.5,"chords":[0,0],"lead":[[0,72,2,0.6]]}
 ],
 "arrangement":["intro","verseA","preChorus","chorus","verseA","preChorus","chorus","bridge","chorusFinal","outro"]}
''';

/// An epic boss/battle track in A minor (i-bVI-bVII), fast and driving.
const String _exemplarBoss = '''
{"title":"Iron Crucible","bpm":172,"root":57,"scale":"minor",
 "sections":[
  {"id":"intro","bars":4,"energy":0.55,"chords":[0,0,5,6],"lead":[[0,57,1,0.7],[2,64,1,0.75],[3,67,1,0.8]]},
  {"id":"verseA","bars":4,"energy":0.75,"chords":[0,5,6,0],"lead":[[0,64,0.5,0.85],[0.5,67,0.25,0.8],[0.75,69,0.25,0.8],[1,71,0.5,0.9],[2,69,0.5,0.85],[2.5,67,0.5,0.8],[3,64,1,0.8]]},
  {"id":"preChorus","bars":4,"energy":0.9,"chords":[5,6,0,4],"lead":[[0,69,0.25,0.9],[0.25,71,0.25,0.9],[0.5,72,0.5,0.9],[1,74,0.5,0.95],[2,76,1,1],[3,79,1,1]]},
  {"id":"chorus","bars":4,"energy":1.0,"chords":[0,5,6,0],"lead":[[0,76,0.5,1],[0.5,74,0.5,0.95],[1,76,0.5,1],[1.5,79,0.5,1],[2,81,1,1],[3,76,0.5,0.95],[3.5,74,0.5,0.9]]},
  {"id":"bridge","bars":4,"energy":0.8,"chords":[3,4,5,6],"lead":[[0,72,0.75,0.85],[1,71,0.75,0.85],[2,69,1,0.8],[3,67,1,0.8]]},
  {"id":"chorusFinal","bars":4,"energy":1.0,"chords":[0,5,6,0],"lead":[[0,76,0.5,1],[0.5,74,0.5,0.95],[1,76,0.5,1],[1.5,79,0.5,1],[2,84,1,1],[3,81,1,1]]},
  {"id":"outro","bars":2,"energy":0.5,"chords":[0,0],"lead":[[0,57,2,0.6]]}
 ],
 "arrangement":["intro","verseA","preChorus","chorus","verseA","chorus","bridge","chorusFinal","outro"]}
''';

const _battleWords = [
  'battle', 'boss', 'fight', 'epic', 'intense', 'dark', 'war', 'storm',
  'fire', 'danger', 'night', 'evil', 'dramatic', 'action', 'бой', 'битв',
  'тёмн', 'темн', 'огонь', 'ночь', 'эпич', 'драк',
];

/// Build the RAG reference block to inject into the prompt.
String buildReference(String prompt) {
  final p = prompt.toLowerCase();
  final boss = _battleWords.any(p.contains);
  final exemplar = boss ? _exemplarBoss : _exemplarHeroic;
  return '$kMoodGuide\n'
      'WORKED EXAMPLE (study the FORMAT, density and quality — do NOT copy these '
      'notes; create your own melody that fits the photo):\n$exemplar';
}
