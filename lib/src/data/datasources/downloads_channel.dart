import 'package:flutter/services.dart';

/// Thin wrapper over the native MethodChannel that writes a file into the
/// public Downloads collection (MediaStore on Android API 29+).
class DownloadsChannel {
  static const MethodChannel _channel = MethodChannel('chiptune_ai/downloads');

  const DownloadsChannel();

  /// Returns a human-readable location of the saved file (e.g.
  /// "Downloads/track_320.mp3").
  Future<String> saveToDownloads(
    String filename,
    Uint8List bytes, {
    String mimeType = 'application/octet-stream',
  }) async {
    final location = await _channel.invokeMethod<String>('saveToDownloads', {
      'filename': filename,
      'bytes': bytes,
      'mimeType': mimeType,
    });
    return location ?? filename;
  }
}
