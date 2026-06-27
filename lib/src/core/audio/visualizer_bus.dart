import 'dart:math';

import 'package:flutter/foundation.dart';

/// A lightweight realtime audio-analysis bus. The PCM player pushes each fed
/// chunk here; a small FFT turns it into [bands] frequency magnitudes that the
/// on-screen visualizer ("полосы волны") listens to. Lives in core so the data
/// layer can publish and the presentation layer can subscribe without coupling.
class VisualizerBus {
  VisualizerBus._();
  static final VisualizerBus instance = VisualizerBus._();

  static const int bands = 28;
  static const int _n = 512; // FFT window

  /// Latest normalized band magnitudes (0..1), length [bands].
  final ValueNotifier<Float32List> levels = ValueNotifier(Float32List(bands));

  final Float64List _re = Float64List(_n);
  final Float64List _im = Float64List(_n);

  /// Feed an interleaved 16-bit stereo PCM chunk; updates [levels].
  void pushPcm16(Uint8List chunkBytes) {
    final bd = ByteData.sublistView(chunkBytes);
    final frames = chunkBytes.length ~/ 4;
    if (frames < 16) return;
    final stride = (frames / _n).floor().clamp(1, 64);
    for (var i = 0; i < _n; i++) {
      final f = i * stride;
      double v = 0;
      if (f < frames) {
        final l = bd.getInt16(f * 4, Endian.little);
        final r = bd.getInt16(f * 4 + 2, Endian.little);
        v = (l + r) / 65536.0;
      }
      final w = 0.5 - 0.5 * cos(2 * pi * i / (_n - 1)); // Hann window
      _re[i] = v * w;
      _im[i] = 0;
    }
    _fft(_re, _im);

    final out = Float32List(bands);
    final half = _n ~/ 2;
    for (var b = 0; b < bands; b++) {
      final lo = pow(half, b / bands).floor().clamp(1, half - 1);
      final hi = pow(half, (b + 1) / bands).ceil().clamp(lo + 1, half);
      var sum = 0.0;
      for (var k = lo; k < hi; k++) {
        sum += sqrt(_re[k] * _re[k] + _im[k] * _im[k]);
      }
      final mag = sum / (hi - lo);
      out[b] = (log(1 + mag * 12) / log(13)).clamp(0.0, 1.0).toDouble();
    }
    levels.value = out;
  }

  void reset() => levels.value = Float32List(bands);

  /// In-place iterative radix-2 FFT.
  static void _fft(Float64List re, Float64List im) {
    final n = re.length;
    var j = 0;
    for (var i = 1; i < n; i++) {
      var bit = n >> 1;
      for (; j & bit != 0; bit >>= 1) {
        j ^= bit;
      }
      j ^= bit;
      if (i < j) {
        var t = re[i];
        re[i] = re[j];
        re[j] = t;
        t = im[i];
        im[i] = im[j];
        im[j] = t;
      }
    }
    for (var len = 2; len <= n; len <<= 1) {
      final ang = -2 * pi / len;
      final wr = cos(ang), wi = sin(ang);
      final half = len >> 1;
      for (var i = 0; i < n; i += len) {
        var cwr = 1.0, cwi = 0.0;
        for (var k = 0; k < half; k++) {
          final a = i + k, b = i + k + half;
          final vr = re[b] * cwr - im[b] * cwi;
          final vi = re[b] * cwi + im[b] * cwr;
          re[b] = re[a] - vr;
          im[b] = im[a] - vi;
          re[a] += vr;
          im[a] += vi;
          final ncwr = cwr * wr - cwi * wi;
          cwi = cwr * wi + cwi * wr;
          cwr = ncwr;
        }
      }
    }
  }
}
