import '../entities/compose_request.dart';
import '../entities/composition.dart';

/// Reports streaming generation progress, 0..1.
typedef ProgressCallback = void Function(double progress);

/// Turns a natural-language request into a structured [Composition] using an
/// AI model. Implemented in the data layer (OpenRouter).
abstract interface class ComposerRepository {
  Future<Composition> compose(ComposeRequest request, {ProgressCallback? onProgress});
}
