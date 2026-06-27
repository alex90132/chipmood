import 'dart:typed_data';

import '../entities/composition.dart';
import '../repositories/file_exporter.dart';
import '../repositories/synth_repository.dart';
import '../../core/util/id3.dart';

/// Use case: render the composition to MP3 and save (then optionally share) it.
class ExportComposition {
  final SynthRepository _synth;
  final FileExporter _exporter;

  const ExportComposition(this._synth, this._exporter);

  /// Renders [composition] to MP3 at [bitrateKbps], writes it to disk and
  /// returns the file path. When [coverArt] is given (the photo that inspired
  /// the track), it's embedded as album art so the saved file shows the cover.
  /// When [share] is true the platform share sheet is opened.
  Future<String> call(
    Composition composition, {
    int bitrateKbps = 320,
    bool share = false,
    Uint8List? coverArt,
  }) async {
    var bytes = await _synth.renderMp3(composition, bitrateKbps: bitrateKbps);
    if (coverArt != null && coverArt.isNotEmpty) {
      bytes = Id3.wrap(bytes, composition.title, coverArt);
    }
    final filename = '${_slug(composition.title)}_$bitrateKbps.mp3';
    final path = await _exporter.save(filename, bytes);
    if (share) {
      await _exporter.share(path, text: '${composition.title} (chiptune)');
    }
    return path;
  }

  String _slug(String title) {
    final cleaned = title
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return cleaned.isEmpty ? 'chiptune' : cleaned;
  }
}
