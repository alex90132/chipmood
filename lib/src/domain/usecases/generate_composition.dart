import '../entities/compose_request.dart';
import '../entities/composition.dart';
import '../repositories/composer_repository.dart';

/// Use case: ask the AI composer for a new composition.
class GenerateComposition {
  final ComposerRepository _composer;

  const GenerateComposition(this._composer);

  Future<Composition> call(ComposeRequest request, {ProgressCallback? onProgress}) {
    return _composer.compose(request, onProgress: onProgress);
  }
}
