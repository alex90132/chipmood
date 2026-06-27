import 'package:meta/meta.dart';

/// ADSR amplitude envelope. Times are in seconds; [sustain] is a level (0..1).
@immutable
class Envelope {
  final double attack;
  final double decay;
  final double sustain;
  final double release;

  const Envelope({
    this.attack = 0.005,
    this.decay = 0.04,
    this.sustain = 0.7,
    this.release = 0.08,
  });

  static const Envelope defaults = Envelope();

  Envelope copyWith({
    double? attack,
    double? decay,
    double? sustain,
    double? release,
  }) {
    return Envelope(
      attack: attack ?? this.attack,
      decay: decay ?? this.decay,
      sustain: sustain ?? this.sustain,
      release: release ?? this.release,
    );
  }
}
