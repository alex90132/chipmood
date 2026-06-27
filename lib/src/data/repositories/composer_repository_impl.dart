import '../../domain/entities/compose_request.dart';
import '../../domain/entities/composition.dart';
import '../../domain/repositories/composer_repository.dart';
import '../arranger/procedural_arranger.dart';
import '../composer/rag_composer.dart';
import '../datasources/openrouter_datasource.dart';
import '../datasources/remote_composer_datasource.dart';
import '../knowledge/groove_library.dart';
import '../knowledge/markov_library.dart';
import '../knowledge/nes_rag.dart';
import '../mappers/composition_mapper.dart';

class ComposerRepositoryImpl implements ComposerRepository {
  final OpenRouterDataSource _openRouter;
  final ProceduralArranger _arranger;
  final RemoteComposerDataSource _neural;
  final CompositionMapper _mapper;
  final NesRag _nesRag;
  final GrooveLibrary _grooves;
  final MarkovLibrary _markov;
  final RagComposer _ragComposer;
  final String Function() _neuralUrl;
  final bool Function() _offline;
  final Future<String?> Function() _bankPath;

  const ComposerRepositoryImpl(
    this._openRouter,
    this._arranger,
    this._neural,
    this._mapper,
    this._nesRag,
    this._grooves,
    this._markov,
    this._ragComposer,
    this._neuralUrl,
    this._offline,
    this._bankPath,
  );

  @override
  Future<Composition> compose(ComposeRequest request,
      {ProgressCallback? onProgress}) async {
    final bank = await _bankPath();
    // Optional neural-server path (Path B).
    if (_neuralUrl().trim().isNotEmpty) {
      onProgress?.call(0.3);
      final song = await _neural.composeSong(request.targetSeconds);
      onProgress?.call(1.0);
      return _mapper
          .fromJson(song, targetSeconds: request.targetSeconds)
          .copyWith(sampleBank: bank);
    }
    final grooves = await _grooves.load();
    final markov = await _markov.load();
    // Offline path: build the whole plan on-device from the pro RAG library —
    // no AI, no network, no credits.
    if (_offline()) {
      onProgress?.call(0.4);
      final plan = await _ragComposer.compose(request.imageBytes);
      onProgress?.call(1.0);
      return _arranger.build(plan,
          targetSeconds: request.targetSeconds,
          grooves: grooves,
          markov: markov,
          sampleBank: bank);
    }
    // AI + RAG: the model composes guided by real examples, then we arrange.
    // If the AI call fails (no credits, offline, error), fall back to the
    // on-device RAG composer so a track always plays.
    try {
      final reference = await _nesRag.fewShot();
      final plan = await _openRouter.composeJson(
        request,
        onProgress: onProgress,
        reference: reference,
      );
      return _arranger.build(plan,
          targetSeconds: request.targetSeconds,
          grooves: grooves,
          markov: markov,
          sampleBank: bank);
    } catch (_) {
      final plan = await _ragComposer.compose(request.imageBytes);
      onProgress?.call(1.0);
      return _arranger.build(plan,
          targetSeconds: request.targetSeconds,
          grooves: grooves,
          markov: markov,
          sampleBank: bank);
    }
  }
}
