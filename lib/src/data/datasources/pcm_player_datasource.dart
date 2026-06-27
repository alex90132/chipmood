import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';

import '../../core/audio/visualizer_bus.dart';
import '../../core/error/failures.dart';
import '../../domain/entities/stream_format.dart';
import '../../domain/repositories/player_repository.dart';

/// Streams PCM to the speakers using flutter_pcm_sound. Audio is pulled on
/// demand from the Rust engine via a [ChunkPuller], so playback starts almost
/// immediately regardless of track length.
///
/// The package exposes no volume control, so we de-click playback ourselves on
/// the raw 16-bit samples: a short fade-in on the first frames (no hard jump
/// from silence) and a graceful fade-out on stop — we keep feeding ramped audio
/// until it reaches zero, then release, so the hardware buffer is never cut
/// mid-waveform.
class PcmPlayerDataSource {
  static const int _framesPerChunk = 8192;

  bool _initialized = false;
  int _sampleRate = 0;
  int _channels = 0;

  ChunkPuller? _pull;
  bool _playing = false;
  bool _feeding = false;

  // De-click state.
  int _framesFed = 0; // absolute frames pushed since play started
  int _fadeInFrames = 0; // length of the start ramp
  bool _fadingOut = false;
  int _fadeOutFrames = 0;
  int _fadeOutPos = 0;
  Completer<void>? _fadeDone;

  bool get isPlaying => _playing;

  Future<void> playStream(StreamFormat format, ChunkPuller pull) async {
    await stop();
    try {
      await _ensureSetup(format.sampleRate, format.channels);
      _pull = pull;
      _playing = true;
      _framesFed = 0;
      _fadingOut = false;
      _fadeOutPos = 0;
      _fadeInFrames = (format.sampleRate * 0.02).round(); // 20 ms
      _fadeOutFrames = (format.sampleRate * 0.18).round(); // 180 ms
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

  /// Apply the fade-in (and, while stopping, the fade-out) ramp to a chunk of
  /// interleaved 16-bit samples, in place.
  void _shape(Uint8List chunk) {
    final ch = _channels <= 0 ? 1 : _channels;
    final s = Int16List.sublistView(chunk);
    final frames = s.length ~/ ch;
    for (var f = 0; f < frames; f++) {
      var g = 1.0;
      final absIn = _framesFed + f;
      if (_fadeInFrames > 0 && absIn < _fadeInFrames) {
        g *= absIn / _fadeInFrames;
      }
      if (_fadingOut && _fadeOutFrames > 0) {
        final p = _fadeOutPos + f;
        g *= p >= _fadeOutFrames ? 0.0 : 1.0 - p / _fadeOutFrames;
      }
      if (g < 0.9999) {
        final base = f * ch;
        for (var c = 0; c < ch; c++) {
          s[base + c] = (s[base + c] * g).round();
        }
      }
    }
    _framesFed += frames;
    if (_fadingOut) _fadeOutPos += frames;
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
      _shape(chunk);
      // Feed the visualizer with the same audio the speakers get.
      VisualizerBus.instance.pushPcm16(chunk);
      await FlutterPcmSound.feed(
        PcmArrayInt16(bytes: ByteData.sublistView(chunk)),
      );
      // Fade-out fully delivered → stop pulling and let the tail drain.
      if (_fadingOut && _fadeOutPos >= _fadeOutFrames) {
        _playing = false;
        _fadeDone?.complete();
      }
    } catch (_) {
      _playing = false;
      _fadeDone?.complete();
    } finally {
      _feeding = false;
    }
  }

  /// Stop playback. When [graceful] (the default) and audio is playing, ramp the
  /// last ~180 ms down to silence before releasing so there is no click.
  Future<void> stop({bool graceful = true}) async {
    if (graceful && _playing && _pull != null) {
      _fadingOut = true;
      _fadeOutPos = 0;
      _fadeDone = Completer<void>();
      // Nudge the feed loop in case the callback is idle.
      _feedNext();
      await _fadeDone!.future
          .timeout(const Duration(milliseconds: 1500), onTimeout: () {});
      // Let the already-queued, now-ramped tail play out of the buffer.
      await Future.delayed(const Duration(milliseconds: 220));
    }
    _playing = false;
    _pull = null;
    _fadingOut = false;
    _fadeDone = null;
    VisualizerBus.instance.reset();
    if (!_initialized) return;
    try {
      await FlutterPcmSound.release();
    } catch (_) {}
    _initialized = false;
  }

  Future<void> dispose() => stop(graceful: false);
}
