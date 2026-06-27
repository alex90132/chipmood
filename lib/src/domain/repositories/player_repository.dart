import 'dart:typed_data';

import '../entities/stream_format.dart';

/// Pulls the next PCM chunk (up to maxFrames stereo frames). Empty = finished.
typedef ChunkPuller = Future<Uint8List> Function(int maxFrames);

/// Plays streamed PCM audio. Implemented in the data layer (flutter_pcm_sound).
abstract interface class PlayerRepository {
  /// Start playback, pulling audio chunks on demand via [pull].
  Future<void> playStream(StreamFormat format, ChunkPuller pull);

  Future<void> stop();
  Future<void> dispose();
}
