import 'package:flutter/foundation.dart';

import '../../core/config/app_config.dart';

@immutable
class SettingsState {
  final String apiKey;
  final String model;

  /// Neural composer server URL. When non-empty, composition uses the trained
  /// model instead of the LLM.
  final String neuralUrl;

  /// When true, compose entirely on-device from the RAG library (no AI calls,
  /// no network/credits needed).
  final bool offline;

  const SettingsState({
    required this.apiKey,
    required this.model,
    required this.neuralUrl,
    this.offline = false,
  });

  factory SettingsState.initial() => SettingsState(
        apiKey: AppConfig.defaultApiKey,
        model: AppConfig.defaultModel,
        neuralUrl: AppConfig.defaultNeuralUrl,
        offline: true, // RAG-only composition by default (no AI/credits needed)
      );

  bool get hasApiKey => apiKey.trim().isNotEmpty;
  bool get useNeural => neuralUrl.trim().isNotEmpty;

  SettingsState copyWith(
      {String? apiKey, String? model, String? neuralUrl, bool? offline}) {
    return SettingsState(
      apiKey: apiKey ?? this.apiKey,
      model: model ?? this.model,
      neuralUrl: neuralUrl ?? this.neuralUrl,
      offline: offline ?? this.offline,
    );
  }
}
