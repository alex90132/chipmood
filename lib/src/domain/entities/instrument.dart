import 'package:meta/meta.dart';

import 'envelope.dart';
import 'waveform.dart';

/// A single voice/timbre chosen by the AI (NES-style: pulses, triangle, noise).
@immutable
class Instrument {
  final String id;
  final Waveform waveform;
  final double duty;
  final double volume;
  final double pan;
  final double glide;
  final double drive;
  final double tone;
  final double crush;
  final double trem;
  final double cutoff;
  final double resonance;
  final double filterEnv;
  final Envelope envelope;

  /// Optional sampler voice: a sample name in the loaded bank, or "@kit" to
  /// pick a drum sample per note. Null = use the oscillator [waveform].
  final String? sample;

  const Instrument({
    required this.id,
    this.waveform = Waveform.square,
    this.duty = 0.5,
    this.volume = 0.8,
    this.pan = 0.0,
    this.glide = 0.0,
    this.drive = 0.0,
    this.tone = 0.5,
    this.crush = 0.0,
    this.trem = 0.0,
    this.cutoff = 1.0,
    this.resonance = 0.0,
    this.filterEnv = 0.0,
    this.envelope = Envelope.defaults,
    this.sample,
  });

  Instrument copyWith({
    double? volume,
    String? sample,
  }) {
    return Instrument(
      id: id,
      waveform: waveform,
      duty: duty,
      volume: volume ?? this.volume,
      pan: pan,
      glide: glide,
      drive: drive,
      tone: tone,
      crush: crush,
      trem: trem,
      cutoff: cutoff,
      resonance: resonance,
      filterEnv: filterEnv,
      envelope: envelope,
      sample: sample ?? this.sample,
    );
  }
}
