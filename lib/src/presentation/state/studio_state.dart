import 'package:flutter/foundation.dart';

import '../../domain/entities/composition.dart';

enum StudioStatus { idle, generating, rendering, playing, exporting, error }

@immutable
class StudioState {
  final StudioStatus status;
  final Composition? composition;

  /// Wall-clock moment playback started (for the realtime visualizer).
  final DateTime? playStartTime;

  /// Actual rendered duration in seconds (from the stream format).
  final double playDurationSeconds;

  /// AI generation progress, 0..1 (driven by the streaming response).
  final double generationProgress;

  /// The captured photo that inspired the track (shown as the vinyl label).
  final Uint8List? coverImage;

  /// Instrument ids the user has muted via the channel buttons. Applied to both
  /// playback and export so a saved track matches what you hear.
  final Set<String> mutedChannels;

  final String? errorMessage;

  const StudioState({
    this.status = StudioStatus.idle,
    this.composition,
    this.playStartTime,
    this.playDurationSeconds = 0,
    this.generationProgress = 0,
    this.coverImage,
    this.mutedChannels = const {},
    this.errorMessage,
  });

  bool get isBusy =>
      status == StudioStatus.generating ||
      status == StudioStatus.rendering ||
      status == StudioStatus.exporting;
  bool get isPlaying => status == StudioStatus.playing;
  bool get hasComposition => composition != null;

  /// Playback progress 0..1 at [now] (for the tonearm).
  double playbackFraction(DateTime now) {
    if (!isPlaying || playStartTime == null || playDurationSeconds <= 0) {
      return 0;
    }
    final e = now.difference(playStartTime!).inMilliseconds / 1000.0;
    return (e / playDurationSeconds).clamp(0.0, 1.0);
  }

  StudioState copyWith({
    StudioStatus? status,
    Composition? composition,
    DateTime? playStartTime,
    double? playDurationSeconds,
    double? generationProgress,
    Uint8List? coverImage,
    Set<String>? mutedChannels,
    String? errorMessage,
    bool clearError = false,
  }) {
    return StudioState(
      status: status ?? this.status,
      composition: composition ?? this.composition,
      playStartTime: playStartTime ?? this.playStartTime,
      playDurationSeconds: playDurationSeconds ?? this.playDurationSeconds,
      generationProgress: generationProgress ?? this.generationProgress,
      coverImage: coverImage ?? this.coverImage,
      mutedChannels: mutedChannels ?? this.mutedChannels,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}
