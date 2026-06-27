import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../controllers/settings_controller.dart';

/// Lets the user enter their OpenRouter API key and pick a model.
class SettingsSheet extends ConsumerStatefulWidget {
  const SettingsSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => const Padding(
        padding: EdgeInsets.only(bottom: 0),
        child: SettingsSheet(),
      ),
    );
  }

  @override
  ConsumerState<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends ConsumerState<SettingsSheet> {
  late final TextEditingController _keyCtrl;
  late final TextEditingController _modelCtrl;
  late final TextEditingController _neuralCtrl;
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(settingsProvider);
    _keyCtrl = TextEditingController(text: settings.apiKey);
    _modelCtrl = TextEditingController(text: settings.model);
    _neuralCtrl = TextEditingController(text: settings.neuralUrl);
  }

  @override
  void dispose() {
    _keyCtrl.dispose();
    _modelCtrl.dispose();
    _neuralCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    // Keep content clear of BOTH the keyboard (viewInsets) and the system
    // navigation bar (viewPadding) so the Save button never hides under it.
    final keyboard = mq.viewInsets.bottom;
    final navBar = mq.viewPadding.bottom;
    final bottom = 20.0 + (keyboard > navBar ? keyboard : navBar);
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Settings', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          TextField(
            controller: _keyCtrl,
            obscureText: _obscure,
            decoration: InputDecoration(
              labelText: 'OpenRouter API key',
              hintText: 'sk-or-...',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _modelCtrl,
            decoration: const InputDecoration(
              labelText: 'Model',
              hintText: 'openai/gpt-4o-mini',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _neuralCtrl,
            decoration: const InputDecoration(
              labelText: 'Neural server URL (Path B)',
              hintText: 'http://192.168.1.59:8000  (empty = use LLM)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'When set, music is composed by your trained model (NES-MDB) and '
            'rendered on the chip. Empty = AI song-plan path.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: ref.watch(settingsProvider).offline,
            onChanged: (v) =>
                ref.read(settingsProvider.notifier).setOffline(v),
            title: const Text('Offline (no AI)'),
            subtitle: const Text(
                'Compose fully on-device from the pro RAG library — no credits.'),
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFFF0D2A8),
                backgroundColor: const Color(0xFFB87333).withValues(alpha: 0.18),
                padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(
                    color: const Color(0xFFE0B080).withValues(alpha: 0.5),
                  ),
                ),
              ),
              onPressed: () {
                ref.read(settingsProvider.notifier)
                  ..setApiKey(_keyCtrl.text.trim())
                  ..setModel(_modelCtrl.text.trim())
                  ..setNeuralUrl(_neuralCtrl.text.trim());
                Navigator.of(context).pop();
              },
              child: const Text('Save'),
            ),
          ),
        ],
      ),
    );
  }
}
