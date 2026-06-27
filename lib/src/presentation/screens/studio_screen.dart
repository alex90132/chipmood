import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../domain/entities/compose_request.dart';
import '../controllers/camera_controller.dart';
import '../controllers/studio_controller.dart';
import '../state/studio_state.dart';
import '../widgets/camera_circle.dart';
import '../widgets/settings_sheet.dart';
import '../widgets/vinyl_player.dart';
import '../widgets/wave_bars.dart';

/// User-selected target duration in seconds (2:34 .. 4:55).
class DurationNotifier extends Notifier<double> {
  @override
  double build() => ComposeRequest.minSeconds;
  void set(double seconds) => state = seconds;
}

final durationProvider =
    NotifierProvider<DurationNotifier, double>(DurationNotifier.new);

class StudioScreen extends ConsumerWidget {
  const StudioScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<StudioState>(studioControllerProvider, (prev, next) {
      if (next.status == StudioStatus.error && next.errorMessage != null) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            content: Text(next.errorMessage!),
            backgroundColor: Theme.of(context).colorScheme.error,
          ));
      }
    });

    final state = ref.watch(studioControllerProvider);
    final showCamera = !state.hasComposition &&
        state.coverImage == null &&
        state.status != StudioStatus.generating;

    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(color: Color(0xFF09060F)),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Deep-space nebula backdrop.
            Image.asset('assets/images/bg_nebula.png', fit: BoxFit.cover),
            // Subtle dark scrim so text/controls stay legible over the photo.
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x33000000), Color(0x99090610)],
                ),
              ),
            ),
            SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final circle = (constraints.maxWidth * 0.74)
                      .clamp(210.0, 300.0)
                      .toDouble();
                  return Column(
                    children: [
                      _TopBar(
                        canCopy: state.hasComposition,
                      ),
                      const Spacer(flex: 2),
                      // Disc/camera sits a little above center.
                      SizedBox(
                        height: circle,
                        child: Center(
                          child: showCamera
                              ? CameraCircle(size: circle)
                              : VinylPlayer(size: circle),
                        ),
                      ),
                      // Fixed-height slot so the disc never shifts; compact bars.
                      SizedBox(
                        height: 44,
                        child: state.isPlaying
                            ? const Padding(
                                padding: EdgeInsets.fromLTRB(24, 8, 24, 0),
                                child: WaveBars(height: 36),
                              )
                            : null,
                      ),
                      // Per-channel mute buttons, right under the equalizer.
                      if (state.hasComposition) const _ChannelMutes(),
                      const Spacer(flex: 3),
                      // Controls live at the bottom, within thumb reach.
                      _BottomArea(showCamera: showCamera),
                      const SizedBox(height: 28),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TopBar extends ConsumerWidget {
  final bool canCopy;
  const _TopBar({required this.canCopy});

  Future<void> _copy(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final json = ref.read(studioControllerProvider.notifier).exportJson();
    if (json == null) return;
    await Clipboard.setData(ClipboardData(text: json));
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Track JSON copied')));
  }

  Future<void> _paste(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (text.trim().isEmpty) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Clipboard has no JSON')));
      return;
    }
    await ref.read(studioControllerProvider.notifier).playFromJson(text);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 6, 6),
      child: Row(
        children: [
          ShaderMask(
            shaderCallback: (r) => const LinearGradient(
              colors: [Color(0xFFF0D2A8), Color(0xFFB87333)],
            ).createShader(r),
            child: Text(
              'ChipMood',
              style: GoogleFonts.audiowide(
                fontSize: 22,
                letterSpacing: 1.0,
                color: Colors.white,
              ),
            ),
          ),
          const Spacer(),
          if (canCopy)
            IconButton(
              tooltip: 'Copy track JSON',
              onPressed: () => _copy(context, ref),
              icon: const Icon(Icons.content_copy_outlined),
            ),
          IconButton(
            tooltip: 'Paste JSON & play',
            onPressed: () => _paste(context, ref),
            icon: const Icon(Icons.content_paste_go_outlined),
          ),
          IconButton(
            tooltip: 'Settings',
            onPressed: () => SettingsSheet.show(context),
            icon: Icon(Icons.settings, color: theme.hintColor),
          ),
        ],
      ),
    );
  }
}

String _fmt(double s) {
  final m = s ~/ 60;
  final sec = (s % 60).round().toString().padLeft(2, '0');
  return '$m:$sec';
}

class _BottomArea extends ConsumerWidget {
  final bool showCamera;
  const _BottomArea({required this.showCamera});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final state = ref.watch(studioControllerProvider);

    if (showCamera) {
      return Column(
        children: [
          const _DurationChips(),
          const SizedBox(height: 18),
          const _ShutterButton(),
          const SizedBox(height: 10),
          Text(
            'Point the camera and tap — a track is composed from your photo',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
        ],
      );
    }

    if (state.status == StudioStatus.generating) {
      return Column(
        children: [
          Text('Composing music from your photo...',
              style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          Text('${(state.generationProgress * 100).round()}%',
              style: theme.textTheme.labelMedium
                  ?.copyWith(color: theme.colorScheme.primary)),
        ],
      );
    }

    final comp = state.composition;
    if (comp == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          Text(
            comp.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 2),
          Text(
            '${comp.bpm.round()} BPM · ${_fmt(comp.targetSeconds)} · ${comp.instrumentCount} voices',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
          const SizedBox(height: 18),
          const _Controls(),
        ],
      ),
    );
  }
}

class _ShutterButton extends ConsumerStatefulWidget {
  const _ShutterButton();

  @override
  ConsumerState<_ShutterButton> createState() => _ShutterButtonState();
}

class _ShutterButtonState extends ConsumerState<_ShutterButton> {
  bool _busy = false;

  Future<void> _shoot() async {
    if (_busy) return;
    setState(() => _busy = true);
    final bytes = await ref.read(cameraProvider.notifier).capture();
    if (!mounted) return;
    final seconds = ref.read(durationProvider);
    setState(() => _busy = false);
    if (bytes != null) {
      // Photo taken — turn the camera off; it's not needed until a new shot.
      await ref.read(cameraProvider.notifier).release();
      await ref
          .read(studioControllerProvider.notifier)
          .generateFromImage(bytes, seconds);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ready = ref.watch(cameraProvider).isReady;
    return SizedBox(
      width: 220,
      height: 56,
      child: FilledButton.icon(
        onPressed: (ready && !_busy) ? _shoot : null,
        icon: _busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.camera_alt),
        label: Text(_busy ? 'Capturing...' : 'Create track'),
      ),
    );
  }
}

class _DurationChips extends ConsumerWidget {
  const _DurationChips();

  static const _options = <double>[154, 225, 295]; // 2:34, 3:45, 4:55

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(durationProvider);
    return Wrap(
      spacing: 10,
      children: [
        for (final secs in _options)
          ChoiceChip(
            label: Text(_fmt(secs)),
            selected: selected == secs,
            onSelected: (_) =>
                ref.read(durationProvider.notifier).set(secs),
          ),
      ],
    );
  }
}

class _Controls extends ConsumerWidget {
  const _Controls();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(studioControllerProvider);
    final controller = ref.read(studioControllerProvider.notifier);
    final playing = state.isPlaying;
    final exporting = state.status == StudioStatus.exporting;

    Future<void> doExport() async {
      final messenger = ScaffoldMessenger.of(context);
      final path = await controller.export(bitrateKbps: 320);
      if (path != null) {
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text('Saved to $path')));
      }
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _SquareButton(
          size: 84,
          gradient: const [Color(0xFFE3A977), Color(0xFF9C5A2C)],
          glow: true,
          onTap: state.isBusy
              ? null
              : (playing ? controller.stop : controller.play),
          child: Icon(playing ? Icons.stop_rounded : Icons.play_arrow_rounded,
              size: 44, color: Colors.white),
        ),
        const SizedBox(width: 18),
        _SquareButton(
          size: 64,
          gradient: const [Color(0xFF6E4A30), Color(0xFF4A301E)],
          onTap: exporting
              ? controller.cancelExport
              : (state.isBusy ? null : doExport),
          child: exporting
              ? const SizedBox(
                  width: 28,
                  height: 28,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      CircularProgressIndicator(strokeWidth: 2),
                      Icon(Icons.stop_rounded,
                          size: 16, color: Color(0xFFF0D2A8)),
                    ],
                  ),
                )
              : const Icon(Icons.download_rounded, color: Color(0xFFF0D2A8)),
        ),
        const SizedBox(width: 18),
        IconButton(
          tooltip: 'New photo',
          onPressed: state.isBusy ? null : controller.reset,
          icon: const Icon(Icons.photo_camera_back_outlined,
              color: Color(0xFFE0B080), size: 26),
        ),
      ],
    );
  }
}

/// A rounded-square (squircle) button with a copper gradient and optional glow.
class _SquareButton extends StatelessWidget {
  final double size;
  final List<Color> gradient;
  final bool glow;
  final VoidCallback? onTap;
  final Widget child;

  const _SquareButton({
    required this.size,
    required this.gradient,
    required this.child,
    this.onTap,
    this.glow = false,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: onTap == null ? 0.5 : 1.0,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(size * 0.3),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: gradient,
          ),
          boxShadow: glow
              ? [
                  BoxShadow(
                    color: gradient.first.withValues(alpha: 0.55),
                    blurRadius: 28,
                    spreadRadius: 1,
                  ),
                ]
              : null,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(size * 0.3),
            onTap: onTap,
            child: Center(child: child),
          ),
        ),
      ),
    );
  }
}

/// A compact row of per-channel mute toggles shown under the equalizer. Tapping
/// a channel mutes/unmutes it live; the choice also carries into the exported
/// track so a saved file matches the current mix.
class _ChannelMutes extends ConsumerWidget {
  const _ChannelMutes();

  static const _channels = <(String, String)>[
    ('lead', 'Lead'),
    ('counter', 'Counter'),
    ('harmony', 'Harmony'),
    ('bass', 'Bass'),
    ('pad', 'Pad'),
    ('arp', 'Arp'),
    ('drums', 'Drums'),
    ('perc', 'Perc'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final muted = ref.watch(studioControllerProvider).mutedChannels;
    final controller = ref.read(studioControllerProvider.notifier);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final (id, label) in _channels)
            _ChannelChip(
              label: label,
              on: !muted.contains(id),
              onTap: () => controller.toggleMute(id),
            ),
        ],
      ),
    );
  }
}

class _ChannelChip extends StatelessWidget {
  final String label;
  final bool on;
  final VoidCallback onTap;
  const _ChannelChip(
      {required this.label, required this.on, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        decoration: BoxDecoration(
          color: on ? const Color(0x33E0B080) : const Color(0x14FFFFFF),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: on ? const Color(0xFFE0B080) : const Color(0x33FFFFFF),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
            color: on ? const Color(0xFFF0D2A8) : Colors.white38,
            decoration: on ? null : TextDecoration.lineThrough,
          ),
        ),
      ),
    );
  }
}
