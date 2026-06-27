import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../core/audio/visualizer_bus.dart';

/// Realtime colored frequency bars (the wave bars) driven by the live audio.
/// Reads [VisualizerBus] and smooths between updates with its own ticker so the
/// bars move fluidly even though the audio analysis arrives a few times/second.
/// Bars are thin pills whose colour sweeps from cool (quiet) to hot (loud) and
/// shimmer with their power.
class WaveBars extends StatefulWidget {
  final double height;
  const WaveBars({super.key, this.height = 90});

  @override
  State<WaveBars> createState() => _WaveBarsState();
}

class _WaveBarsState extends State<WaveBars>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final Float32List _display = Float32List(VisualizerBus.bands);
  double _phase = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick)..start();
  }

  void _tick(Duration elapsed) {
    _phase = elapsed.inMicroseconds / 1e6;
    final target = VisualizerBus.instance.levels.value;
    var active = false;
    for (var i = 0; i < _display.length && i < target.length; i++) {
      final t = target[i];
      // Fast attack, slow decay — classic VU/eq feel.
      final next = t > _display[i]
          ? _display[i] + (t - _display[i]) * 0.55
          : _display[i] + (t - _display[i]) * 0.11;
      _display[i] = next;
      if (next > 0.01) active = true;
    }
    // Keep repainting while there's any energy so the shimmer animates smoothly.
    if (active && mounted) setState(() {});
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      child: CustomPaint(
        size: Size.infinite,
        painter: _BarsPainter(Float32List.fromList(_display), _phase),
      ),
    );
  }
}

class _BarsPainter extends CustomPainter {
  final Float32List levels;
  final double phase;
  _BarsPainter(this.levels, this.phase);

  @override
  void paint(Canvas canvas, Size size) {
    final n = levels.length;
    if (n == 0) return;
    final slot = size.width / n;
    // Thin pills: each bar takes ~45% of its slot, the rest is breathing space.
    final bw = (slot * 0.45).clamp(1.5, 7.0);
    final radius = Radius.circular(bw / 2);

    for (var i = 0; i < n; i++) {
      final lv = levels[i].clamp(0.0, 1.0);
      if (lv <= 0.01) continue;
      // Power shimmer: louder bars flicker more (and faster), quiet ones are calm.
      final flick = 1.0 + 0.22 * lv * math.sin(phase * 11.0 + i * 0.7);
      final h = (lv * size.height * flick).clamp(2.0, size.height);
      final x = i * slot + (slot - bw) / 2;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, size.height - h, bw, h),
        radius,
      );

      // Colour by POWER: cool cyan/blue when quiet → green/yellow → hot orange
      // / red when loud, with a touch of per-bar spectrum tint and shimmer.
      final hue = (200.0 * (1.0 - lv) + 12.0 * math.sin(i * 0.5)) % 360.0;
      final sat = (0.55 + 0.45 * lv).clamp(0.0, 1.0);
      final val = (0.55 + 0.45 * lv) * flick;
      final color = HSVColor.fromAHSV(
        0.9,
        hue < 0 ? hue + 360 : hue,
        sat,
        val.clamp(0.0, 1.0),
      ).toColor();

      // Glow grows with power — bright bars bloom, quiet ones stay crisp.
      if (lv > 0.35) {
        final glow = Paint()
          ..color = color.withValues(alpha: 0.35 * lv)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 2.0 + 6.0 * lv);
        canvas.drawRRect(rect, glow);
      }
      canvas.drawRRect(rect, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(_BarsPainter oldDelegate) =>
      oldDelegate.phase != phase || oldDelegate.levels != levels;
}
