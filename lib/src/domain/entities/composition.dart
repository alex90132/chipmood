import 'package:meta/meta.dart';

import 'instrument.dart';
import 'pattern.dart';

/// A full song produced by the AI composer: a compact set of instruments and
/// patterns plus an arrangement. The Rust engine expands and loops the
/// arrangement to fill [targetSeconds].
@immutable
class Composition {
  final String title;

  /// Tempo, chosen by the AI.
  final double bpm;
  final int sampleRate;
  final double masterVolume;

  /// Tempo-synced master echo/delay wetness, 0..1 (0 = off).
  final double delayWet;

  /// Desired output duration in seconds (chosen by the user).
  final double targetSeconds;

  final List<Instrument> instruments;
  final List<Pattern> patterns;
  final List<String> arrangement;

  /// Optional path to a packed sample bank to load before rendering (enables
  /// the real-instrument sampler voices referenced by instruments' [sample]).
  final String? sampleBank;

  const Composition({
    this.title = 'Untitled',
    this.bpm = 120,
    this.sampleRate = 44100,
    this.masterVolume = 0.85,
    this.delayWet = 0.0,
    this.targetSeconds = 60,
    this.instruments = const [],
    this.patterns = const [],
    this.arrangement = const [],
    this.sampleBank,
  });

  int get instrumentCount => instruments.length;
  int get patternCount => patterns.length;
  int get noteCount => patterns.fold(0, (sum, p) => sum + p.noteCount);

  /// Number of sections in the arrangement (falls back to pattern count).
  int get sectionCount =>
      arrangement.isNotEmpty ? arrangement.length : patterns.length;

  double get durationSeconds => targetSeconds;

  Composition copyWith({
    String? title,
    double? bpm,
    int? sampleRate,
    double? masterVolume,
    double? delayWet,
    double? targetSeconds,
    List<Instrument>? instruments,
    List<Pattern>? patterns,
    List<String>? arrangement,
    String? sampleBank,
  }) {
    return Composition(
      title: title ?? this.title,
      bpm: bpm ?? this.bpm,
      sampleRate: sampleRate ?? this.sampleRate,
      masterVolume: masterVolume ?? this.masterVolume,
      delayWet: delayWet ?? this.delayWet,
      targetSeconds: targetSeconds ?? this.targetSeconds,
      instruments: instruments ?? this.instruments,
      patterns: patterns ?? this.patterns,
      arrangement: arrangement ?? this.arrangement,
      sampleBank: sampleBank ?? this.sampleBank,
    );
  }
}
