import '../../domain/entities/stream_format.dart';
import '../../domain/repositories/player_repository.dart';
import '../datasources/pcm_player_datasource.dart';

class PlayerRepositoryImpl implements PlayerRepository {
  final PcmPlayerDataSource _dataSource;

  const PlayerRepositoryImpl(this._dataSource);

  @override
  Future<void> playStream(StreamFormat format, ChunkPuller pull) =>
      _dataSource.playStream(format, pull);

  @override
  Future<void> stop() => _dataSource.stop();

  @override
  Future<void> dispose() => _dataSource.dispose();
}
