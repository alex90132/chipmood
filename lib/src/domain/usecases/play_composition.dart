import '../entities/composition.dart';
import '../entities/stream_format.dart';
import '../repositories/player_repository.dart';
import '../repositories/synth_repository.dart';

/// Use case: stream a composition from the Rust engine and play it back with
/// minimal latency. Returns the stream format (for duration / visualization).
class PlayComposition {
  final SynthRepository _synth;
  final PlayerRepository _player;

  const PlayComposition(this._synth, this._player);

  Future<StreamFormat> call(Composition composition) async {
    final format = await _synth.startStream(composition);
    await _player.playStream(format, _synth.nextChunk);
    return format;
  }

  Future<void> stop() async {
    await _player.stop();
    await _synth.stopStream();
  }
}
