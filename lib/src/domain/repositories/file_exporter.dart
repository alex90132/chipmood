/// Persists exported audio to a file and optionally shares it.
/// Implemented in the data layer (path_provider + share_plus).
abstract interface class FileExporter {
  /// Writes [bytes] to a file named [filename] and returns its absolute path.
  Future<String> save(String filename, List<int> bytes);

  /// Opens the platform share sheet for the file at [path].
  Future<void> share(String path, {String? text});
}
