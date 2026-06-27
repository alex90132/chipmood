import 'dart:typed_data';

import '../entities/composition.dart';
import '../entities/stream_format.dart';

/// Renders compositions via the Rust engine. Supports low-latency streaming
/// playback (chunked) and full-buffer export (WAV/MP3).
abstract interface class SynthRepository {
  /// Start a streaming session for [composition]; returns the audio format.
  Future<StreamFormat> startStream(Composition composition);

  /// Pull the next chunk (up to [maxFrames] stereo frames) of 16-bit PCM.
  /// Empty when the song is finished.
  Future<Uint8List> nextChunk(int maxFrames);

  /// Stop and release the current streaming session.
  Future<void> stopStream();

  /// Render to a complete WAV file (for export).
  Future<List<int>> renderWav(Composition composition);

  /// Render to an MP3 file at the given CBR bitrate in kbps (e.g. 320).
  Future<List<int>> renderMp3(Composition composition, {int bitrateKbps = 320});
}
