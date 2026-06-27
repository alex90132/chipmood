import 'dart:typed_data';

import '../../domain/entities/composition.dart';
import '../../domain/entities/stream_format.dart';
import '../../domain/repositories/synth_repository.dart';
import '../datasources/rust_synth_datasource.dart';

class SynthRepositoryImpl implements SynthRepository {
  final RustSynthDataSource _dataSource;

  const SynthRepositoryImpl(this._dataSource);

  @override
  Future<StreamFormat> startStream(Composition composition) =>
      _dataSource.startStream(composition);

  @override
  Future<Uint8List> nextChunk(int maxFrames) =>
      _dataSource.nextChunk(maxFrames);

  @override
  Future<void> stopStream() => _dataSource.stopStream();

  @override
  Future<List<int>> renderWav(Composition composition) =>
      _dataSource.renderWav(composition);

  @override
  Future<List<int>> renderMp3(Composition composition, {int bitrateKbps = 320}) =>
      _dataSource.renderMp3(composition, bitrateKbps: bitrateKbps);
}
