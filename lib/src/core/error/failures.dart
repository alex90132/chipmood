/// Base type for recoverable, user-facing errors in the app.
sealed class Failure implements Exception {
  final String message;
  const Failure(this.message);

  @override
  String toString() => message;
}

/// The OpenRouter API call failed (network, auth, rate limit, etc.).
class ComposerFailure extends Failure {
  const ComposerFailure(super.message);
}

/// The AI returned content that could not be parsed into a [Composition].
class CompositionParseFailure extends Failure {
  const CompositionParseFailure(super.message);
}

/// The Rust synthesis engine rejected the composition.
class SynthFailure extends Failure {
  const SynthFailure(super.message);
}

/// Audio playback failed.
class PlaybackFailure extends Failure {
  const PlaybackFailure(super.message);
}

/// Required configuration is missing (e.g. API key not set).
class ConfigFailure extends Failure {
  const ConfigFailure(super.message);
}
