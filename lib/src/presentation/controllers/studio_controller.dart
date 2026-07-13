import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/error/failures.dart';
import '../../data/composer/ai_remix_prompt.dart';
import '../../domain/entities/compose_request.dart';
import '../../domain/entities/composition.dart';
import '../providers/providers.dart';
import '../state/studio_state.dart';

/// Orchestrates the generate -> render -> play flow and exposes UI state.
class StudioController extends Notifier<StudioState> {
  Timer? _playbackTimer;
  int _exportRun = 0;

  @override
  StudioState build() {
    ref.onDispose(() => _playbackTimer?.cancel());
    return const StudioState();
  }

  /// Compose a track from a captured photo, then start playback automatically.
  Future<void> generateFromImage(Uint8List image, double seconds) async {
    if (state.isBusy) return;
    _playbackTimer?.cancel();
    await ref.read(playCompositionProvider).stop();
    state = state.copyWith(
      status: StudioStatus.generating,
      generationProgress: 0,
      coverImage: image,
      composition: null,
      clearError: true,
    );
    try {
      final composition = await ref.read(generateCompositionProvider)(
        ComposeRequest(imageBytes: image, targetSeconds: seconds),
        onProgress: (p) {
          if (state.status == StudioStatus.generating) {
            state = state.copyWith(generationProgress: p);
          }
        },
      );
      state = state.copyWith(
        status: StudioStatus.idle,
        composition: composition,
        generationProgress: 1,
      );
      debugPrint('[COMPOSE] "${composition.title}" '
          '${composition.bpm.round()}bpm ${composition.sectionCount} sections '
          '${composition.instrumentCount} voices');
      // Playback is started by the tonearm when it touches the record
      // (see VinylPlayer), so it lines up with the visual.
    } catch (e) {
      _fail(e);
    }
  }

  /// Ask the AI to compose a new track.
  Future<void> generate(ComposeRequest request) async {
    if (state.isBusy) return;
    _playbackTimer?.cancel();
    state = state.copyWith(
      status: StudioStatus.generating,
      generationProgress: 0,
      clearError: true,
    );
    try {
      final composition = await ref.read(generateCompositionProvider)(
        request,
        onProgress: (p) {
          if (state.status == StudioStatus.generating) {
            state = state.copyWith(generationProgress: p);
          }
        },
      );
      state = state.copyWith(
        status: StudioStatus.idle,
        composition: composition,
      );
    } catch (e) {
      _fail(e);
    }
  }

  /// Render the current composition with Rust and stream it.
  Future<void> play() async {
    final composition = state.composition;
    if (composition == null || state.isBusy) return;
    _playbackTimer?.cancel();
    await ref.read(playCompositionProvider).stop();
    state = state.copyWith(status: StudioStatus.rendering, clearError: true);
    try {
      final format =
          await ref.read(playCompositionProvider)(_withMutes(composition));
      final seconds = format.durationSeconds > 0
          ? format.durationSeconds
          : composition.targetSeconds;
      state = state.copyWith(
        status: StudioStatus.playing,
        playStartTime: DateTime.now(),
        playDurationSeconds: seconds,
      );
      final ms = (seconds * 1000).ceil() + 400;
      _playbackTimer = Timer(Duration(milliseconds: ms), () {
        if (state.status == StudioStatus.playing) {
          state = state.copyWith(status: StudioStatus.idle);
        }
      });
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> stop() async {
    _playbackTimer?.cancel();
    await ref.read(playCompositionProvider).stop();
    if (state.status == StudioStatus.playing) {
      state = state.copyWith(status: StudioStatus.idle);
    }
  }

  /// Mute/unmute one instrument channel. Applies live (restarts playback with
  /// the new mix) and also affects export, so a saved track matches the mix.
  Future<void> toggleMute(String id) async {
    final next = Set<String>.from(state.mutedChannels);
    if (!next.remove(id)) next.add(id);
    state = state.copyWith(mutedChannels: next);
    if (state.status == StudioStatus.playing) {
      await play(); // restart the stream with the updated mix
    }
  }

  /// Apply the user's channel mutes to a composition (muted = volume 0).
  Composition _withMutes(Composition c) {
    if (state.mutedChannels.isEmpty) return c;
    final muted = state.mutedChannels;
    return c.copyWith(
      instruments: [
        for (final i in c.instruments)
          muted.contains(i.id) ? i.copyWith(volume: 0.0) : i
      ],
    );
  }

  /// Render the current composition to MP3 and share it. Returns the file path
  /// on success, or null on failure (the error is surfaced via state).
  Future<String?> export({int bitrateKbps = 320}) async {
    final composition = state.composition;
    if (composition == null || state.isBusy) return null;
    _playbackTimer?.cancel();
    await ref.read(playCompositionProvider).stop();
    final run = ++_exportRun;
    state = state.copyWith(status: StudioStatus.exporting, clearError: true);
    try {
      final path = await ref.read(exportCompositionProvider)(
        _withMutes(composition),
        bitrateKbps: bitrateKbps,
        coverArt: state.coverImage,
      );
      if (run != _exportRun) return null; // cancelled — ignore the result
      state = state.copyWith(status: StudioStatus.idle);
      return path;
    } catch (e) {
      if (run != _exportRun) return null;
      _fail(e);
      return null;
    }
  }

  /// Cancel an in-progress export: unblocks the UI immediately (the underlying
  /// render finishes in the background and its result is discarded).
  void cancelExport() {
    if (state.status == StudioStatus.exporting) {
      _exportRun++;
      state = state.copyWith(status: StudioStatus.idle);
    }
  }

  /// Human-sounding AI-chat prompt for the Copy button: craft tips + 1–2 real
  /// RAG hit phrases + a tiny skeleton of the current track. Paste the AI's
  /// reply (a song-plan JSON) via [playFromJson].
  Future<String?> exportAiPrompt() async {
    final c = state.composition;
    if (c == null) return null;
    // Mood guess from tempo so the hit phrases match the track's energy.
    final bpm = c.bpm;
    final mood = bpm >= 150
        ? 'tense'
        : bpm >= 125
            ? 'happy'
            : bpm >= 95
                ? 'calm'
                : 'sad';
    List<Map<String, dynamic>> hits = const [];
    try {
      hits = await ref.read(nesRagProvider).pickHitPhrases(count: 2, mood: mood);
    } catch (_) {}
    return const AiRemixPrompt().build(c, hits: hits);
  }

  /// Full composition JSON (debug / backup). Prefer [exportAiPrompt] for chats.
  String? exportJson() {
    final c = state.composition;
    if (c == null) return null;
    final mapper = ref.read(compositionMapperProvider);
    return const JsonEncoder.withIndent('  ').convert(mapper.toJson(c));
  }

  /// Load a track from pasted text. Accepts:
  ///  1) a ChipMood *song plan* (sections + arrangement) — arranged on-device,
  ///  2) a full composition JSON (patterns + instruments).
  /// Markdown fences / surrounding prose from chat replies are stripped.
  Future<void> playFromJson(String text) async {
    if (state.isBusy) return;
    final trimmed = _extractJson(text);
    if (trimmed.isEmpty) {
      _fail(const CompositionParseFailure('Clipboard is empty.'));
      return;
    }
    _playbackTimer?.cancel();
    await ref.read(playCompositionProvider).stop();
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map<String, dynamic>) {
        throw const CompositionParseFailure('Expected a JSON object.');
      }
      final composition = await _compositionFromPaste(decoded);
      if (composition.patterns.isEmpty) {
        throw const CompositionParseFailure('No patterns in JSON.');
      }
      // Show the player (no cover) and let the tonearm start playback.
      state = const StudioState().copyWith(
        status: StudioStatus.idle,
        composition: composition,
      );
    } catch (e) {
      _fail(e is Failure
          ? e
          : CompositionParseFailure('Invalid JSON: $e'));
    }
  }

  Future<Composition> _compositionFromPaste(Map<String, dynamic> json) async {
    final hasPlan = json['sections'] is List &&
        (json['sections'] as List).isNotEmpty &&
        json['patterns'] == null;
    if (hasPlan) {
      final grooves = await ref.read(grooveLibraryProvider).load();
      final markov = await ref.read(markovLibraryProvider).load();
      final seconds = (json['target_seconds'] as num?)?.toDouble() ??
          (json['seconds'] as num?)?.toDouble() ??
          state.composition?.targetSeconds ??
          154;
      return ref.read(proceduralArrangerProvider).build(
            json,
            targetSeconds: seconds,
            grooves: grooves,
            markov: markov,
          );
    }
    return ref.read(compositionMapperProvider).fromJson(json);
  }

  /// Pull a JSON object out of a chat reply (fences / leading prose).
  static String _extractJson(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return '';
    final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```', multiLine: true);
    final m = fence.firstMatch(text);
    if (m != null) text = m.group(1)!.trim();
    if (!text.startsWith('{')) {
      final s = text.indexOf('{');
      final e = text.lastIndexOf('}');
      if (s != -1 && e > s) text = text.substring(s, e + 1);
    }
    return text;
  }

  void _fail(Object error) {
    final message = error is Failure ? error.message : error.toString();
    debugPrint('StudioController error: $message');
    state = state.copyWith(status: StudioStatus.error, errorMessage: message);
  }

  /// Return to the camera to shoot a new photo.
  Future<void> reset() async {
    _playbackTimer?.cancel();
    await ref.read(playCompositionProvider).stop();
    state = const StudioState();
  }
}

final studioControllerProvider =
    NotifierProvider<StudioController, StudioState>(StudioController.new);
