import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/settings_state.dart';

class SettingsController extends Notifier<SettingsState> {
  @override
  SettingsState build() => SettingsState.initial();

  void setApiKey(String key) => state = state.copyWith(apiKey: key);

  void setModel(String model) => state = state.copyWith(model: model);

  void setNeuralUrl(String url) => state = state.copyWith(neuralUrl: url.trim());

  void setOffline(bool v) => state = state.copyWith(offline: v);
}

final settingsProvider =
    NotifierProvider<SettingsController, SettingsState>(SettingsController.new);
