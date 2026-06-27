import 'dart:typed_data';

import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';

import '../../core/audio/visualizer_bus.dart';
import '../../core/error/failures.dart';
import '../../domain/entities/stream_format.dart';
import '../../domain/repositories/player_repository.dart';

/// Streams PCM to the speakers using flutter_pcm_sound. Audio is pulled on
/// demand from the Rust engine via a [ChunkPuller], so playback starts almost
/// immediately regardless of track length.
class PcmPlayerDataSource {
  static const int _framesPerChunk = 8192;

  bool _initialized = false;
  int _sampleRate = 0;
  int _channels = 0;

  ChunkPuller? _pull;
  bool _playing = false;
  bool _feeding = false;

  bool get isPlaying => _playing;

  Future<void> playStream(StreamFormat format, ChunkPuller pull) async {
    await stop();
    try {
      await _ensureSetup(format.sampleRate, format.channels);
      _pull = pull;
      _playing = true;
      FlutterPcmSound.setFeedThreshold(_framesPerChunk);
      FlutterPcmSound.setFeedCallback(_onFeed);
      // Prime the buffer; subsequent feeds are driven by the callback.
      await _feedNext();
      FlutterPcmSound.start();
    } catch (e) {
      _playing = false;
      throw PlaybackFailure('Could not start playback: $e');
    }
  }

  Future<void> _ensureSetup(int sampleRate, int channels) async {
    if (_initialized && sampleRate == _sampleRate && channels == _channels) {
      return;
    }
    await FlutterPcmSound.setup(
      sampleRate: sampleRate,
      channelCount: channels,
    );
    _sampleRate = sampleRate;
    _channels = channels;
    _initialized = true;
  }

  void _onFeed(int remainingFrames) {
    if (!_playing) return;
    _feedNext();
  }

  Future<void> _feedNext() async {
    if (!_playing || _feeding || _pull == null) return;
    _feeding = true;
    try {
      final chunk = await _pull!(_framesPerChunk);
      if (!_playing) return;
      if (chunk.isEmpty) {
        _playing = false;
        return;
      }
      // Feed the visualizer with the same audio the speakers get.
      VisualizerBus.instance.pushPcm16(chunk);
      await FlutterPcmSound.feed(
        PcmArrayInt16(bytes: ByteData.sublistView(chunk)),
      );
    } catch (_) {
      _playing = false;
    } finally {
      _feeding = false;
    }
  }

  Future<void> stop() async {
    _playing = false;
    _pull = null;
    VisualizerBus.instance.reset();
    if (!_initialized) return;
    try {
      await FlutterPcmSound.release();
    } catch (_) {}
    _initialized = false;
  }

  Future<void> dispose() => stop();
}
