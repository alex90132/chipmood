import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/composition.dart';
import '../controllers/studio_controller.dart';
import '../state/studio_state.dart';

/// The photo becomes a spinning vinyl record. A tonearm swings down onto the
/// disc; the moment its needle touches the groove, playback begins. During
/// playback the needle slowly travels toward the center (the progress bar).
class VinylPlayer extends ConsumerStatefulWidget {
  final double size;
  const VinylPlayer({super.key, required this.size});

  @override
  ConsumerState<VinylPlayer> createState() => _VinylPlayerState();
}

class _VinylPlayerState extends ConsumerState<VinylPlayer>
    with TickerProviderStateMixin {
  late final AnimationController _spin;
  late final AnimationController _arm;
  Composition? _droppedFor;

  @override
  void initState() {
    super.initState();
    _spin = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    _arm = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..addStatusListener((s) {
        // Needle has reached the record -> start the music.
        if (s == AnimationStatus.completed) {
          ref.read(studioControllerProvider.notifier).play();
        }
      });
  }

  @override
  void dispose() {
    _spin.dispose();
    _arm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(studioControllerProvider);

    // Spin while generating, dropping the arm, or playing.
    final spinning = state.status == StudioStatus.generating ||
        state.isPlaying ||
        _arm.isAnimating;
    if (spinning) {
      if (!_spin.isAnimating) _spin.repeat();
    } else if (_spin.isAnimating) {
      _spin.stop();
    }

    // Trigger the tonearm drop once when a fresh composition is ready.
    final comp = state.composition;
    if (comp != null &&
        state.status == StudioStatus.idle &&
        !identical(comp, _droppedFor)) {
      _droppedFor = comp;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _arm.forward(from: 0);
      });
    }
    if (comp == null) {
      _droppedFor = null;
      _arm.value = 0;
    }

    final s = widget.size;
    final image = state.coverImage;

    return SizedBox(
      width: s,
      height: s,
      child: AnimatedBuilder(
        animation: Listenable.merge([_spin, _arm]),
        builder: (context, _) {
          final st = ref.read(studioControllerProvider);
          return Stack(
            alignment: Alignment.center,
            children: [
              Transform.rotate(
                angle: _spin.value * 2 * math.pi,
                child: _Disc(size: s * 0.84, image: image),
              ),
              CustomPaint(
                size: Size(s, s),
                painter: _TonearmPainter(tip: _needleTip(st, s)),
              ),
            ],
          );
        },
      ),
    );
  }

  Offset _needleTip(StudioState st, double s) {
    final center = Offset(s / 2, s / 2);
    final discR = s * 0.42;
    final dir = Offset(math.cos(-1.0), math.sin(-1.0)); // up-right
    final outer = center + dir * (discR * 0.92);
    final inner = center + dir * (discR * 0.30);
    final rest = Offset(s * 0.86, s * 0.30);

    if (st.isPlaying) {
      return Offset.lerp(outer, inner, st.playbackFraction(DateTime.now()))!;
    }
    // Dropping (or dropped/idle with a composition): rest -> contact.
    return Offset.lerp(rest, outer, _arm.value)!;
  }
}

class _Disc extends StatelessWidget {
  final double size;
  final dynamic image; // Uint8List?
  const _Disc({required this.size, required this.image});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.6),
            blurRadius: 22,
            spreadRadius: 1,
          ),
        ],
      ),
      child: ClipOval(
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (image != null)
              Image.memory(image, fit: BoxFit.cover)
            else
              const ColoredBox(color: Colors.black),
            CustomPaint(painter: _GroovesPainter(hasImage: image != null)),
          ],
        ),
      ),
    );
  }
}

/// Concentric vinyl grooves + center label/hole drawn over the photo.
class _GroovesPainter extends CustomPainter {
  final bool hasImage;
  _GroovesPainter({required this.hasImage});

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;

    canvas.drawCircle(c, r, Paint()..color = Colors.black.withValues(alpha: 0.18));

    final groove = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.black.withValues(alpha: 0.18);
    for (double rr = r * 0.30; rr < r * 0.98; rr += 3.0) {
      canvas.drawCircle(c, rr, groove);
    }
    canvas.drawCircle(
      c,
      r - 1,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = Colors.black.withValues(alpha: 0.55),
    );

    if (hasImage) {
      // Picture disc: keep the photo visible — only a small spindle hole.
      canvas.drawCircle(c, r * 0.05,
          Paint()..color = Colors.black.withValues(alpha: 0.35));
      _spindleHole(canvas, c, r);
      return;
    }

    // Classic bronze center label.
    final labelR = r * 0.32;
    final label = Paint()
      ..shader = const RadialGradient(
        colors: [Color(0xFFEAC489), Color(0xFFC1853F), Color(0xFF8A571F)],
        stops: [0.0, 0.6, 1.0],
      ).createShader(Rect.fromCircle(center: c, radius: labelR));
    canvas.drawCircle(c, labelR, label);
    canvas.drawCircle(
      c,
      labelR,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.black.withValues(alpha: 0.35),
    );
    // a faint inner ring on the label for the printed-paper look
    canvas.drawCircle(
      c,
      labelR * 0.62,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.black.withValues(alpha: 0.12),
    );
    _spindleHole(canvas, c, r);
  }

  void _spindleHole(Canvas canvas, Offset c, double r) {
    // The actual hole — small, never painted over the whole center.
    canvas.drawCircle(c, r * 0.028, Paint()..color = const Color(0xFF0B0A08));
  }

  @override
  bool shouldRepaint(_GroovesPainter oldDelegate) =>
      oldDelegate.hasImage != hasImage;
}

/// A metallic tonearm from a fixed pivot to the moving needle [tip].
class _TonearmPainter extends CustomPainter {
  final Offset tip;
  _TonearmPainter({required this.tip});

  @override
  void paint(Canvas canvas, Size size) {
    final pivot = Offset(size.width * 0.88, size.height * 0.10);

    canvas.drawLine(
      pivot,
      tip,
      Paint()
        ..color = const Color(0xFFCBD5E1)
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawLine(
      pivot,
      tip,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.35)
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );

    canvas.drawCircle(pivot, 12, Paint()..color = const Color(0xFF94A3B8));
    canvas.drawCircle(
      pivot,
      12,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.black.withValues(alpha: 0.3),
    );

    canvas.drawCircle(tip, 7, Paint()..color = const Color(0xFFE2E8F0));
    canvas.drawCircle(
      tip,
      10,
      Paint()..color = const Color(0xFF22D3EE).withValues(alpha: 0.45),
    );
    canvas.drawCircle(tip, 3, Paint()..color = const Color(0xFF22D3EE));
  }

  @override
  bool shouldRepaint(_TonearmPainter oldDelegate) => oldDelegate.tip != tip;
}
