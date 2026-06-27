import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

/// Copies the packed real-instrument sample bank asset to a real file on disk
/// (the Rust sampler reads it by path) and caches the location. Returns null if
/// anything fails, so the engine simply falls back to the chip oscillators.
class SampleBankInstaller {
  static const _asset = 'assets/samples/ut_bank.bin';
  String? _path;

  Future<String?> ensure() async {
    if (_path != null) return _path;
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/ut_bank.bin');
      final data = await rootBundle.load(_asset);
      final bytes = data.buffer.asUint8List();
      // Rewrite only if missing or a different size (cheap version check).
      if (!file.existsSync() || file.lengthSync() != bytes.length) {
        await file.writeAsBytes(bytes, flush: true);
      }
      _path = file.path;
      return _path;
    } catch (_) {
      return null;
    }
  }
}
