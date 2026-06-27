import 'dart:typed_data';

import 'package:meta/meta.dart';

/// What the user gives the AI composer. The AI has full creative freedom over
/// style, key, tempo and instrumentation; the only constraint is duration.
@immutable
class ComposeRequest {
  /// Minimum / maximum allowed track length in seconds (2:34 .. 4:55).
  static const double minSeconds = 154;
  static const double maxSeconds = 295;

  /// Optional text description (may be empty when composing from a photo).
  final String prompt;

  /// JPEG/PNG bytes of the captured photo the music is inspired by.
  final Uint8List? imageBytes;

  /// Desired output duration in seconds (clamped to [minSeconds, maxSeconds]).
  final double targetSeconds;

  ComposeRequest({
    this.prompt = '',
    this.imageBytes,
    double targetSeconds = minSeconds,
  }) : targetSeconds = targetSeconds.clamp(minSeconds, maxSeconds);

  bool get hasImage => imageBytes != null && imageBytes!.isNotEmpty;
}
