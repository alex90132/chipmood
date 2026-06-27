import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

@immutable
class CameraState {
  final CameraController? controller;
  final bool initializing;
  final String? error;

  const CameraState({this.controller, this.initializing = false, this.error});

  bool get isReady => controller?.value.isInitialized ?? false;

  CameraState copyWith({
    CameraController? controller,
    bool? initializing,
    String? error,
    bool clearError = false,
  }) {
    return CameraState(
      controller: controller ?? this.controller,
      initializing: initializing ?? this.initializing,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Owns the device camera used to photograph a scene for the composer.
class CameraNotifier extends Notifier<CameraState> {
  bool _disposing = false;

  @override
  CameraState build() {
    ref.onDispose(() {
      _disposing = true;
      state.controller?.dispose();
    });
    return const CameraState();
  }

  Future<void> ensureInitialized() async {
    if (state.isReady || state.initializing) return;
    state = state.copyWith(initializing: true, clearError: true);
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        state = state.copyWith(initializing: false, error: 'No camera found.');
        return;
      }
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        back,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await controller.initialize();
      if (_disposing) {
        await controller.dispose();
        return;
      }
      state = state.copyWith(controller: controller, initializing: false);
    } catch (e) {
      state = state.copyWith(
        initializing: false,
        error: 'Camera unavailable: $e',
      );
    }
  }

  /// Capture a still photo and return its bytes (JPEG).
  Future<Uint8List?> capture() async {
    final c = state.controller;
    if (c == null || !c.value.isInitialized || c.value.isTakingPicture) {
      return null;
    }
    try {
      final file = await c.takePicture();
      return await file.readAsBytes();
    } catch (e) {
      state = state.copyWith(error: 'Capture failed: $e');
      return null;
    }
  }

  /// Release the camera (turn it off) when it's no longer needed — e.g. after a
  /// photo has been taken, or when the app is backgrounded. Re-acquired lazily
  /// by [ensureInitialized] when the camera view is shown again.
  Future<void> release() async {
    if (state.initializing) return;
    final c = state.controller;
    if (c == null) return;
    state = const CameraState();
    try {
      await c.dispose();
    } catch (_) {}
  }
}

final cameraProvider =
    NotifierProvider<CameraNotifier, CameraState>(CameraNotifier.new);
