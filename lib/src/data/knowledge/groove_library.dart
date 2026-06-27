import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

/// Reusable, key-agnostic musical "parts" mined from real chiptunes:
///  * [grooves]  — a representative 1-bar drum beat (+ its hiss↔ring tone),
///                 so the actual drum RHYTHM and sound come from real music.
///  * [basslines]— a 1-bar bass rhythm + pitch contour (semitones from its
///                 first note), transposed onto each track's chords.
///  * [fills]    — 1-bar drum sbivki for section ends.
///  * [voicings] — real chord shapes for the sustained pad.
class GrooveBeat {
  /// Each hit: [startBeat, drumPitch, durBeat, velocity].
  final List<List<double>> notes;

  /// Noise colour suggested by this groove (0 = hiss .. 1 = ring).
  final double tone;
  const GrooveBeat(this.notes, this.tone);
}

class GrooveData {
  /// Each fill: list of [startBeat, drumPitch, durBeat, velocity].
  final List<List<List<double>>> fills;

  /// Each voicing: semitone intervals above the chord root, e.g. [0,4,7].
  final List<List<int>> voicings;

  /// Real drum beats (one bar each).
  final List<GrooveBeat> grooves;

  /// Real bass patterns: each a list of [startBeat, semisFromFirst, dur, vel].
  final List<List<List<double>>> basslines;

  /// Real harmony/comp patterns (same contour format as basslines).
  final List<List<List<double>>> harmonies;

  /// Real busy arpeggio-like patterns (contour format).
  final List<List<List<double>>> arps;

  /// Real lead phrases for melody fallback (contour format).
  final List<List<List<double>>> melodies;

  /// Production presets (effect amounts) derived from real songs' character.
  final List<Map<String, dynamic>> profiles;

  const GrooveData(this.fills, this.voicings, this.grooves, this.basslines,
      this.harmonies, this.arps, this.melodies, this.profiles);
  static const empty = GrooveData([], [], [], [], [], [], [], []);

  bool get isEmpty => fills.isEmpty && voicings.isEmpty && grooves.isEmpty;
}

class GrooveLibrary {
  GrooveData? _data;

  Future<GrooveData> load() async {
    if (_data != null) return _data!;
    try {
      final raw = await rootBundle.loadString('assets/rag/grooves.json');
      final m = jsonDecode(raw) as Map<String, dynamic>;
      List<List<double>> rows(dynamic v) => (v as List)
          .map<List<double>>(
              (n) => (n as List).map((x) => (x as num).toDouble()).toList())
          .toList();
      final fills = ((m['fills'] as List?) ?? const [])
          .map<List<List<double>>>(rows)
          .toList();
      final voicings = ((m['voicings'] as List?) ?? const [])
          .map<List<int>>((v) => (v as List).map((x) => (x as num).toInt()).toList())
          .where((v) => v.length >= 3)
          .toList();
      final grooves = ((m['grooves'] as List?) ?? const [])
          .map<GrooveBeat>((g) {
            final gm = g as Map<String, dynamic>;
            return GrooveBeat(rows(gm['p']), (gm['tone'] as num?)?.toDouble() ?? 0.5);
          })
          .where((g) => g.notes.isNotEmpty)
          .toList();
      final basslines = ((m['basslines'] as List?) ?? const [])
          .map<List<List<double>>>(rows)
          .where((b) => b.isNotEmpty)
          .toList();
      final harmonies = ((m['harmonies'] as List?) ?? const [])
          .map<List<List<double>>>(rows)
          .where((b) => b.isNotEmpty)
          .toList();
      final arps = ((m['arps'] as List?) ?? const [])
          .map<List<List<double>>>(rows)
          .where((b) => b.isNotEmpty)
          .toList();
      final melodies = ((m['melodies'] as List?) ?? const [])
          .map<List<List<double>>>(rows)
          .where((b) => b.isNotEmpty)
          .toList();
      final profiles = ((m['profiles'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();
      _data = GrooveData(
          fills, voicings, grooves, basslines, harmonies, arps, melodies, profiles);
    } catch (_) {
      _data = GrooveData.empty;
    }
    return _data!;
  }
}
