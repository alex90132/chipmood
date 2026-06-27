import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../controllers/camera_controller.dart';

/// Circular live camera preview (capture is triggered by the bottom button).
class CameraCircle extends ConsumerStatefulWidget {
  final double size;
  const CameraCircle({super.key, required this.size});

  @override
  ConsumerState<CameraCircle> createState() => _CameraCircleState();
}

class _CameraCircleState extends ConsumerState<CameraCircle>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(cameraProvider.notifier).ensureInitialized();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    // Turn the camera off when the app is backgrounded; bring it back on resume.
    if (lifecycle == AppLifecycleState.inactive ||
        lifecycle == AppLifecycleState.paused) {
      ref.read(cameraProvider.notifier).release();
    } else if (lifecycle == AppLifecycleState.resumed && mounted) {
      ref.read(cameraProvider.notifier).ensureInitialized();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cam = ref.watch(cameraProvider);
    final s = widget.size;

    Widget inner;
    if (cam.error != null) {
      inner = _Message(icon: Icons.no_photography, text: cam.error!);
    } else if (!cam.isReady) {
      inner = const Center(child: CircularProgressIndicator());
    } else {
      inner = FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: cam.controller!.value.previewSize?.height ?? s,
          height: cam.controller!.value.previewSize?.width ?? s,
          child: CameraPreview(cam.controller!),
        ),
      );
    }

    return Container(
      width: s,
      height: s,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: const Color(0xFF22D3EE).withValues(alpha: 0.6),
          width: 3,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF22D3EE).withValues(alpha: 0.22),
            blurRadius: 28,
            spreadRadius: 2,
          ),
        ],
      ),
      child: ClipOval(child: SizedBox(width: s, height: s, child: inner)),
    );
  }
}

class _Message extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Message({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white54, size: 36),
            const SizedBox(height: 10),
            Text(text,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
