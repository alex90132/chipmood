import 'dart:math' as math;

import 'package:meta/meta.dart';

/// A single note event placed on the beat grid.
@immutable
class Note {
  /// MIDI note number (60 = middle C). A negative value denotes a rest.
  final int pitch;

  /// Start position in beats from the beginning of the track.
  final double start;

  /// Duration in beats.
  final double duration;

  /// Velocity, 0..1.
  final double velocity;

  /// Tracker-style hardware arpeggio: semitone offsets rapidly cycled with the
  /// base pitch (e.g. [4,7] plays a major chord on one channel). Empty = off.
  final List<int> arp;

  /// Pitch slide (portamento) in semitones reached across the note (0 = off).
  final double slide;

  /// Per-note vibrato depth 0..1 (0 = engine default for sustained notes).
  final double vib;

  /// Retrigger/stutter count within the note (0 or 1 = once).
  final int retrig;

  /// Note delay in beats (lay-back groove).
  final double delay;

  const Note({
    required this.pitch,
    required this.start,
    required this.duration,
    this.velocity = 1.0,
    this.arp = const [],
    this.slide = 0.0,
    this.vib = 0.0,
    this.retrig = 0,
    this.delay = 0.0,
  });

  bool get isRest => pitch < 0;

  /// Frequency in Hz (A4 = 440 Hz). Mirrors the Rust engine, useful for the UI.
  double get frequency {
    if (isRest) return 0;
    return 440.0 * math.pow(2, (pitch - 69) / 12.0).toDouble();
  }

  Note copyWith({
    int? pitch,
    double? start,
    double? duration,
    double? velocity,
    List<int>? arp,
    double? slide,
    double? vib,
    int? retrig,
    double? delay,
  }) {
    return Note(
      pitch: pitch ?? this.pitch,
      start: start ?? this.start,
      duration: duration ?? this.duration,
      velocity: velocity ?? this.velocity,
      arp: arp ?? this.arp,
      slide: slide ?? this.slide,
      vib: vib ?? this.vib,
      retrig: retrig ?? this.retrig,
      delay: delay ?? this.delay,
    );
  }
}
