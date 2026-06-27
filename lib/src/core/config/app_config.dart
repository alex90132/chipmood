/// Static configuration for external services.
///
/// The OpenRouter API key is intentionally NOT hardcoded here. It is provided
/// at runtime through the settings provider (and can be injected at build time
/// via `--dart-define=OPENROUTER_API_KEY=...`).
class AppConfig {
  static const String openRouterBaseUrl = 'https://openrouter.ai/api/v1';

  /// Neural chiptune composer server (your GPU box on the LAN). When set, the
  /// app composes via the trained model instead of the LLM. Empty = use LLM+RAG.
  static const String defaultNeuralUrl = '';

  /// Default model: a fast, vision-capable model so photo->track is quick.
  /// (qwen/qwen3.7-plus was ~95s; this is ~3s.) Change it in Settings anytime.
  static const String defaultModel = 'google/gemini-3-flash-preview';

  /// Disable model "thinking"/reasoning tokens for faster, cheaper, clean JSON.
  static const bool disableReasoning = true;

  /// Optional headers OpenRouter uses for attribution / rankings.
  static const String appReferer = 'https://github.com/example/chiptune_ai';
  static const String appTitle = 'ChipMood';

  /// API key injected at build time, if any. Empty when not provided.
  static const String envApiKey =
      String.fromEnvironment('OPENROUTER_API_KEY', defaultValue: '');

  /// The effective default key. No key is baked into the app — it must be
  /// injected at build time via --dart-define=OPENROUTER_API_KEY=... (otherwise
  /// the app composes fully offline from the on-device RAG library).
  static String get defaultApiKey => envApiKey;
}
