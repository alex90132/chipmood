import 'package:meta/meta.dart';

/// Audio format of a streaming playback session.
@immutable
class StreamFormat {
  final int sampleRate;
  final int channels;
  final int totalFrames;

  const StreamFormat({
    required this.sampleRate,
    required this.channels,
    required this.totalFrames,
  });

  double get durationSeconds =>
      sampleRate == 0 ? 0 : totalFrames / sampleRate;
}
