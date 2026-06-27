import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/arranger/procedural_arranger.dart';
import '../../data/composer/rag_composer.dart';
import '../../data/datasources/file_exporter_datasource.dart';
import '../../data/datasources/openrouter_datasource.dart';
import '../../data/datasources/pcm_player_datasource.dart';
import '../../data/datasources/remote_composer_datasource.dart';
import '../../data/datasources/rust_synth_datasource.dart';
import '../../data/knowledge/groove_library.dart';
import '../../data/knowledge/markov_library.dart';
import '../../data/knowledge/nes_rag.dart';
import '../../data/knowledge/sample_bank.dart';
import '../../data/mappers/composition_mapper.dart';
import '../../data/repositories/composer_repository_impl.dart';
import '../../data/repositories/file_exporter_impl.dart';
import '../../data/repositories/player_repository_impl.dart';
import '../../data/repositories/synth_repository_impl.dart';
import '../../domain/repositories/composer_repository.dart';
import '../../domain/repositories/file_exporter.dart';
import '../../domain/repositories/player_repository.dart';
import '../../domain/repositories/synth_repository.dart';
import '../../domain/usecases/export_composition.dart';
import '../../domain/usecases/generate_composition.dart';
import '../../domain/usecases/play_composition.dart';
import '../controllers/settings_controller.dart';

/// Dependency-injection wiring. Each layer depends only on abstractions; the
/// concrete implementations are assembled here.

// ---- Infrastructure --------------------------------------------------------

final dioProvider = Provider<Dio>((ref) {
  final dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 20),
    receiveTimeout: const Duration(seconds: 120),
  ));
  ref.onDispose(dio.close);
  return dio;
});

final compositionMapperProvider =
    Provider<CompositionMapper>((ref) => const CompositionMapper());

final proceduralArrangerProvider =
    Provider<ProceduralArranger>((ref) => const ProceduralArranger());

final nesRagProvider = Provider<NesRag>((ref) => NesRag());

final grooveLibraryProvider = Provider<GrooveLibrary>((ref) => GrooveLibrary());

final markovLibraryProvider = Provider<MarkovLibrary>((ref) => MarkovLibrary());

final sampleBankInstallerProvider =
    Provider<SampleBankInstaller>((ref) => SampleBankInstaller());

final ragComposerProvider = Provider<RagComposer>((ref) {
  return RagComposer(ref.watch(nesRagProvider), ref.watch(grooveLibraryProvider));
});

// ---- Data sources ----------------------------------------------------------

final openRouterDataSourceProvider = Provider<OpenRouterDataSource>((ref) {
  return OpenRouterDataSource(
    ref.watch(dioProvider),
    () => ref.read(settingsProvider).apiKey,
    () => ref.read(settingsProvider).model,
  );
});

final remoteComposerDataSourceProvider =
    Provider<RemoteComposerDataSource>((ref) {
  return RemoteComposerDataSource(
    ref.watch(dioProvider),
    () => ref.read(settingsProvider).neuralUrl,
  );
});

final rustSynthDataSourceProvider = Provider<RustSynthDataSource>((ref) {
  return RustSynthDataSource(ref.watch(compositionMapperProvider));
});

final pcmPlayerDataSourceProvider = Provider<PcmPlayerDataSource>((ref) {
  final ds = PcmPlayerDataSource();
  ref.onDispose(ds.dispose);
  return ds;
});

final fileExporterDataSourceProvider = Provider<FileExporterDataSource>((ref) {
  return const FileExporterDataSource();
});

// ---- Repositories ----------------------------------------------------------

final composerRepositoryProvider = Provider<ComposerRepository>((ref) {
  return ComposerRepositoryImpl(
    ref.watch(openRouterDataSourceProvider),
    ref.watch(proceduralArrangerProvider),
    ref.watch(remoteComposerDataSourceProvider),
    ref.watch(compositionMapperProvider),
    ref.watch(nesRagProvider),
    ref.watch(grooveLibraryProvider),
    ref.watch(markovLibraryProvider),
    ref.watch(ragComposerProvider),
    () => ref.read(settingsProvider).neuralUrl,
    () => ref.read(settingsProvider).offline,
    // Sampler rolled back: keep the pure on-chip PCM synth ("the soul"). The
    // bank is not loaded, so the engine plays its oscillator voices. (Flip this
    // back to the installer to re-enable the real-instrument sampler.)
    () async => null,
  );
});

final synthRepositoryProvider = Provider<SynthRepository>((ref) {
  return SynthRepositoryImpl(ref.watch(rustSynthDataSourceProvider));
});

final playerRepositoryProvider = Provider<PlayerRepository>((ref) {
  return PlayerRepositoryImpl(ref.watch(pcmPlayerDataSourceProvider));
});

final fileExporterProvider = Provider<FileExporter>((ref) {
  return FileExporterImpl(ref.watch(fileExporterDataSourceProvider));
});

// ---- Use cases -------------------------------------------------------------

final generateCompositionProvider = Provider<GenerateComposition>((ref) {
  return GenerateComposition(ref.watch(composerRepositoryProvider));
});

final playCompositionProvider = Provider<PlayComposition>((ref) {
  return PlayComposition(
    ref.watch(synthRepositoryProvider),
    ref.watch(playerRepositoryProvider),
  );
});

final exportCompositionProvider = Provider<ExportComposition>((ref) {
  return ExportComposition(
    ref.watch(synthRepositoryProvider),
    ref.watch(fileExporterProvider),
  );
});
