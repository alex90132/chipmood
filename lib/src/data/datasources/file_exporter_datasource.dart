import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/error/failures.dart';
import '../../domain/repositories/file_exporter.dart';
import 'downloads_channel.dart';

/// Saves exported audio. On Android the file goes straight into the public
/// Downloads folder (MediaStore). On other platforms it is written to the app
/// documents directory and can be shared.
class FileExporterDataSource implements FileExporter {
  final DownloadsChannel _downloads;

  const FileExporterDataSource([this._downloads = const DownloadsChannel()]);

  @override
  Future<String> save(String filename, List<int> bytes) async {
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    try {
      if (!kIsWeb && Platform.isAndroid) {
        return await _downloads.saveToDownloads(
          filename,
          data,
          mimeType: _mimeFor(filename),
        );
      }
      final dir = await getApplicationDocumentsDirectory();
      final exportsDir = Directory('${dir.path}/exports');
      if (!await exportsDir.exists()) {
        await exportsDir.create(recursive: true);
      }
      final file = File('${exportsDir.path}/$filename');
      await file.writeAsBytes(data, flush: true);
      return file.path;
    } catch (e) {
      throw PlaybackFailure('Could not save export: $e');
    }
  }

  @override
  Future<void> share(String path, {String? text}) async {
    try {
      await SharePlus.instance.share(
        ShareParams(files: [XFile(path)], text: text),
      );
    } catch (e) {
      throw PlaybackFailure('Could not open share sheet: $e');
    }
  }

  String _mimeFor(String filename) {
    final f = filename.toLowerCase();
    if (f.endsWith('.mp3')) return 'audio/mpeg';
    if (f.endsWith('.wav')) return 'audio/wav';
    return 'application/octet-stream';
  }
}
