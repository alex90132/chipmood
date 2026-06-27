import '../../domain/repositories/file_exporter.dart';
import '../datasources/file_exporter_datasource.dart';

class FileExporterImpl implements FileExporter {
  final FileExporterDataSource _dataSource;

  const FileExporterImpl(this._dataSource);

  @override
  Future<String> save(String filename, List<int> bytes) =>
      _dataSource.save(filename, bytes);

  @override
  Future<void> share(String path, {String? text}) =>
      _dataSource.share(path, text: text);
}
