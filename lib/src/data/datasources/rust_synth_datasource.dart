import 'dart:convert';
import 'dart:typed_data';

import '../../core/error/failures.dart';
import '../../domain/entities/composition.dart';
import '../../domain/entities/stream_format.dart';
import '../../rust/api/synth.dart' as rust;
import '../mappers/composition_mapper.dart';

/// Bridges the domain layer to the Rust synthesis engine via flutter_rust_bridge.
class RustSynthDataSource {
  final CompositionMapper _mapper;

  const RustSynthDataSource(this._mapper);

  Future<StreamFormat> startStream(Composition composition) async {
    final json = jsonEncode(_mapper.toJson(composition));
    try {
      final info = await rust.streamStart(
        songJson: json,
        targetSeconds: composition.targetSeconds,
      );
      return StreamFormat(
        sampleRate: info.sampleRate,
        channels: info.channels,
        totalFrames: info.totalFrames.toInt(),
      );
    } catch (e) {
      throw SynthFailure('Rust stream start failed: $e');
    }
  }

  Future<Uint8List> nextChunk(int maxFrames) {
    return rust.streamNextChunk(maxFrames: maxFrames);
  }

  Future<void> stopStream() => rust.streamStop();

  Future<List<int>> renderWav(Composition composition) async {
    final json = jsonEncode(_mapper.toJson(composition));
    try {
      return await rust.synthesizeWav(
        songJson: json,
        targetSeconds: composition.targetSeconds,
      );
    } catch (e) {
      throw SynthFailure('Rust WAV synthesis failed: $e');
    }
  }

  Future<List<int>> renderMp3(
    Composition composition, {
    int bitrateKbps = 320,
  }) async {
    final json = jsonEncode(_mapper.toJson(composition));
    try {
      return await rust.synthesizeMp3(
        songJson: json,
        targetSeconds: composition.targetSeconds,
        bitrateKbps: bitrateKbps,
      );
    } catch (e) {
      throw SynthFailure('Rust MP3 synthesis failed: $e');
    }
  }
}
