/// Oscillator timbres supported by the Rust synthesis engine.
///
/// The wire value (used in JSON exchanged with the AI composer and the Rust
/// engine) is the lowercase enum name.
enum Waveform {
  square,
  pulse,
  triangle,
  sawtooth,
  sine,
  noise;

  String get wire => name;

  static Waveform fromWire(String value) {
    return Waveform.values.firstWhere(
      (w) => w.name == value.toLowerCase(),
      orElse: () => Waveform.square,
    );
  }
}
