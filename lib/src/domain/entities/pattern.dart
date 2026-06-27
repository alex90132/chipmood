import 'package:meta/meta.dart';

import 'note.dart';

/// One instrument lane inside a pattern.
@immutable
class PatternTrack {
  final String instrumentId;
  final List<Note> notes;

  const PatternTrack({required this.instrumentId, this.notes = const []});
}

/// A reusable musical block (intro, verse, chorus, bridge, fill...).
@immutable
class Pattern {
  final String id;

  /// Length in beats. 0 means "derive from the notes".
  final double lengthBeats;
  final List<PatternTrack> tracks;

  const Pattern({
    required this.id,
    this.lengthBeats = 0,
    this.tracks = const [],
  });

  int get noteCount =>
      tracks.fold(0, (sum, t) => sum + t.notes.where((n) => !n.isRest).length);
}
