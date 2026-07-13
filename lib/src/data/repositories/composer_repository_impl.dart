import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../domain/entities/compose_request.dart';
import '../../domain/entities/composition.dart';
import '../../domain/repositories/composer_repository.dart';
import '../arranger/procedural_arranger.dart';
import '../composer/rag_composer.dart';
import '../critic/hit_critic.dart';
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

  static const _critic = HitCritic();

  /// Candidates generated per tap. Only the critic's winner is ever heard —
  /// generation is symbolic (no audio), so this costs milliseconds.
  static const _offlineCandidates = 12;
  static const _aiArrangeCandidates = 8;

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
      onProgress?.call(0.15);
      return _bestOffline(request, grooves, markov, bank, onProgress);
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
      return _bestArrangement(plan, request.targetSeconds, grooves, markov,
          bank, onProgress);
    } catch (_) {
      onProgress?.call(0.15);
      return _bestOffline(request, grooves, markov, bank, onProgress);
    }
  }

  /// THE HIT TRICK, offline edition: compose many complete candidate tracks
  /// (different exemplar, key, tempo, groove, timbres each time), score every
  /// one with [HitCritic], and return only the winner. The duds are discarded
  /// unheard, so the app's floor quality rises to the critic's floor.
  Future<Composition> _bestOffline(
    ComposeRequest request,
    GrooveData grooves,
    MarkovModel? markov,
    String? bank,
    ProgressCallback? onProgress,
  ) async {
    Composition? best;
    var bestScore = -1.0;
    for (var i = 0; i < _offlineCandidates; i++) {
      final plan = await _ragComposer.compose(request.imageBytes);
      final c = _arranger.build(plan,
          targetSeconds: request.targetSeconds,
          grooves: grooves,
          markov: markov,
          sampleBank: bank);
      final s = _critic.score(c);
      if (s > bestScore) {
        bestScore = s;
        best = c;
      }
      onProgress?.call(0.15 + 0.85 * (i + 1) / _offlineCandidates);
      // Yield between candidates so the UI/progress ring stays fluid.
      await Future<void>.delayed(Duration.zero);
    }
    debugPrint('[CRITIC] best of $_offlineCandidates -> '
        '${bestScore.toStringAsFixed(3)} "${best!.title}"');
    return best;
  }

  /// The hit trick for AI plans: the AI's notes are fixed, but the arranger's
  /// seed controls groove, timbres, textures and effects. Re-arrange the same
  /// plan under several seeds and keep the reading the critic likes most —
  /// like a producer auditioning takes of the same song.
  Composition _bestArrangement(
    Map<String, dynamic> plan,
    double targetSeconds,
    GrooveData grooves,
    MarkovModel? markov,
    String? bank,
    ProgressCallback? onProgress,
  ) {
    final rng = Random();
    Composition? best;
    var bestScore = -1.0;
    for (var i = 0; i < _aiArrangeCandidates; i++) {
      final candidate = Map<String, dynamic>.from(plan);
      // Take 1 honors the plan's own seed (reproducibility of a pasted plan
      // is handled by the arranger, not here); the rest audition new ones.
      if (i > 0 || candidate['seed'] == null) {
        candidate['seed'] = 1 + rng.nextInt(0x7FFFFFFE);
      }
      final c = _arranger.build(candidate,
          targetSeconds: targetSeconds,
          grooves: grooves,
          markov: markov,
          sampleBank: bank);
      final s = _critic.score(c);
      if (s > bestScore) {
        bestScore = s;
        best = c;
      }
    }
    onProgress?.call(1.0);
    debugPrint('[CRITIC] best arrangement of $_aiArrangeCandidates -> '
        '${bestScore.toStringAsFixed(3)}');
    return best!;
  }
}
