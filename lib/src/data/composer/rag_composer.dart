import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../knowledge/groove_library.dart';
import '../knowledge/nes_rag.dart';

/// Builds a complete song "plan" (the same JSON the AI would return) ENTIRELY
/// on-device from the professional RAG library — no AI, no network, no credits.
///
/// The photo (if any) picks the mood via simple colour analysis; a real
/// exemplar of that mood supplies the scale, tempo, chords, timbre and the
/// genuine lead/harmony/counter/bass/drums phrases; a RAG production profile
/// supplies the effects. The arranger then performs it just like an AI plan.
class RagComposer {
  final NesRag _rag;
  final GrooveLibrary _grooves;

  const RagComposer(this._rag, this._grooves);

  Future<Map<String, dynamic>> compose(Uint8List? image, {int? seed}) async {
    final rng = Random(seed ?? DateTime.now().microsecondsSinceEpoch);
    // Continuous valence/arousal from the photo (not just a quadrant): they
    // finely steer tempo and scale brightness, so "slightly happy" and "very
    // happy" photos yield different tracks.
    final (mood, valence, arousal) = image != null
        ? await _analyzeImage(image)
        : (_randomMood(rng), rng.nextDouble(), rng.nextDouble());

    final grooves = await _grooves.load();
    // COHERENCE FIRST: take the whole melodic backbone — lead, harmony,
    // counter, bass, chords, scale, tempo — from ONE professional exemplar
    // (a pro wrote those voices together, in one key, over one progression, so
    // the melody actually lands on its harmony). Mashing voices from different
    // songs is what made tracks sound like "a random set of notes". Variety
    // BETWEEN tracks instead comes from a different exemplar each time plus the
    // transpose, tempo jitter, real song FORM, and the per-seed groove /
    // bassline / timbres / production the arranger already varies.
    // UT stays the primary inspiration (~half the time), but the rest of the
    // time we draw from the whole, now-smarter pool (POP909 chords, EMOPIA's
    // precise moods, NES/VGM) so tracks vary more and match mood better.
    final ex = await _rag.pickFull(mood,
        rng: rng, prefer: rng.nextBool() ? const ['ut'] : null);
    if (ex == null) {
      return _fallback(mood, rng);
    }

    // Choose a key so tracks differ; exemplars are normalized to C (60).
    final root = 57 + rng.nextInt(8); // 57..64
    final shift = root - 60;
    // Scale brightness from valence; tempo nudged by arousal (on top of jitter).
    final exScale = (ex['scale'] as String?) ?? 'minor';
    final scale = valence > 0.62 ? 'major' : (valence < 0.38 ? 'minor' : exScale);
    final bpm = ((ex['bpm'] as num?)?.toInt() ?? 132) +
        rng.nextInt(11) -
        5 +
        ((arousal - 0.5) * 24).round();
    final chords = ((ex['chords'] as List?) ?? const [0, 0, 0, 0, 0, 0, 0, 0])
        .map((e) => (e as num).toInt())
        .toList();

    // All voices from the SAME exemplar -> they agree harmonically. The
    // arranger snaps them into [scale] and performs them.
    final lead = _voice(ex['lead'], shift);
    final harmony = _voice(ex['harmony'], shift);
    final counter = _voice(ex['counter'] ?? ex['lead'], shift);
    final bass = _voice(ex['bass'], shift);
    final drums = _voice(ex['drums'], 0); // (the arranger uses a RAG groove)

    // Distinct real SECTIONS captured from the same pro track (verse / chorus /
    // bridge), each with its own melody, harmony, bass and chords — these let us
    // build a through-composed song instead of looping one 8-bar idea.
    final parts = (ex['parts'] as List?)?.whereType<Map>().toList() ?? const [];

    // A 4-bar section built straight from one real part (already re-zeroed).
    Map<String, dynamic> partSection(String id, Map part, double energy,
        {bool withLead = true, bool withCounter = false, bool thin = false}) {
      final pch = ((part['chords'] as List?) ?? const [0, 0, 0, 0])
          .map((e) => (e as num).toInt())
          .toList();
      return {
        'id': id,
        'bars': 4,
        'energy': energy,
        'chords': pch,
        'lead': withLead ? _voice(part['lead'], shift) : const <List<num>>[],
        'harmony': thin ? const <List<num>>[] : _voice(part['harmony'], shift),
        if (withCounter) 'counter': _voice(part['counter'], shift),
        'bass': _voice(part['bass'], shift),
        'drums': _voice(part['drums'], 0),
      };
    }

    List<int> ch(int loBar, int hiBar) {
      final out = <int>[];
      for (var b = loBar; b < hiBar; b++) {
        out.add(chords.isEmpty ? 0 : chords[b % chords.length]);
      }
      return out;
    }

    // Slice the 8-bar exemplar phrases into 4-bar sections (re-zeroed).
    Map<String, dynamic> section(
        String id, int loBar, double energy,
        {bool withLead = true, bool withCounter = false, bool thin = false}) {
      final lo = loBar * 4.0, hi = lo + 16.0;
      List<List<num>> slice(List<List<num>> v, {bool drop = false}) {
        if (drop) return const [];
        final out = <List<num>>[];
        for (final n in v) {
          final s = n[0].toDouble();
          if (s >= lo && s < hi) {
            out.add([s - lo, n[1], n[2], n[3]]);
          }
        }
        return out;
      }

      return {
        'id': id,
        'bars': 4,
        'energy': energy,
        'chords': ch(loBar, loBar + 4),
        'lead': slice(lead, drop: !withLead),
        'harmony': slice(harmony, drop: thin),
        if (withCounter) 'counter': slice(counter),
        'bass': slice(bass),
        'drums': slice(drums),
      };
    }

    // A real arc derived from a genuine UT99 song FORM (its order list distilled
    // to a letter sequence like "ABCBDCEF..."). Each distinct letter becomes a
    // section with its own character; the engine then plays intro once, loops
    // the long varied body, and plays the outro once — so tracks get authentic,
    // non-repetitive structure instead of a fixed verse/chorus loop.
    final form = await _rag.pickStructure(rng: rng);
    List<Map<String, dynamic>> sections;
    List<String> arrangement;
    if (parts.length >= 2 && form != null && form.length >= 4) {
      // Map the real letter form onto the real distinct parts: each different
      // letter gets its OWN section (its own melody+harmony+bass), so the song
      // genuinely develops; repeated letters bring their section back (a real
      // hook/verse return) — that's song-writing, not a loop.
      final freq = <String, int>{};
      final letters = <String>[];
      for (final c in form.split('')) {
        freq[c] = (freq[c] ?? 0) + 1;
        if (!letters.contains(c)) letters.add(c);
      }
      final palette = letters.take(7).toList();
      final hook =
          palette.reduce((a, b) => (freq[b] ?? 0) > (freq[a] ?? 0) ? b : a);
      // the most melodic part is the chorus material
      var hookPi = 0;
      var bestE = -1.0;
      for (var i = 0; i < parts.length; i++) {
        final e = (parts[i]['energy'] as num?)?.toDouble() ?? 0.6;
        if (e > bestE) {
          bestE = e;
          hookPi = i;
        }
      }
      sections = <Map<String, dynamic>>[];
      final idOf = <String, String>{};
      var cyc = 0;
      for (var j = 0; j < palette.length; j++) {
        final L = palette[j];
        final isIntro = j == 0;
        final isHook = L == hook && !isIntro;
        final id = isIntro ? 'intro' : (isHook ? 'chorus_$L' : 'sec_$L');
        idOf[L] = id;
        final pi = isIntro ? 0 : (isHook ? hookPi : (cyc++ % parts.length));
        final part = parts[pi];
        final pe = (part['energy'] as num?)?.toDouble() ?? 0.7;
        final energy = isIntro ? 0.4 : (isHook ? 1.0 : pe.clamp(0.55, 0.95));
        sections.add(partSection(id, part, energy,
            withLead: !isIntro,
            withCounter: isHook || j.isOdd,
            thin: isIntro));
      }
      sections.add(partSection('outro', parts[0], 0.5, withLead: false));
      final body = <String>[];
      for (final c in form.split('')) {
        final id = idOf[c];
        if (id != null && id != 'intro') body.add(id);
        if (body.length >= 14) break;
      }
      if (body.isEmpty) {
        body.add(idOf[palette.length > 1 ? palette[1] : palette[0]]!);
      }
      // A BREAKDOWN then a LIFTED final chorus (+2 key change) for a real
      // climax: strip back, then the chorus returns a whole step higher. Both
      // reuse the chorus part's melody so harmony stays intact.
      final chorusId = idOf[hook];
      if (chorusId != null && parts.isNotEmpty) {
        sections.add(partSection('breakdown', parts[hookPi], 0.5,
            withLead: true, thin: true));
        sections.add(partSection('chorusFinal', parts[hookPi], 1.0,
            withLead: true, withCounter: true));
        final at = body.lastIndexOf(chorusId);
        if (at >= 0) {
          body[at] = 'chorusFinal';          // last chorus becomes the climax
          body.insert(at, 'breakdown');      // breakdown right before it
        } else {
          body.addAll(['breakdown', 'chorusFinal']);
        }
      }
      arrangement = ['intro', ...body, 'outro'];
    } else if (form != null && form.length >= 4) {
      // Fallback (exemplar without multi-part data): use the 8-bar phrase split
      // into two coherent halves (verse = bars 0-4, chorus = bars 4-8).
      final freq = <String, int>{};
      final letters = <String>[];
      for (final c in form.split('')) {
        freq[c] = (freq[c] ?? 0) + 1;
        if (!letters.contains(c)) letters.add(c);
      }
      final palette = letters.take(7).toList();
      final hook =
          palette.reduce((a, b) => (freq[b] ?? 0) > (freq[a] ?? 0) ? b : a);
      sections = <Map<String, dynamic>>[];
      final idOf = <String, String>{};
      for (var j = 0; j < palette.length; j++) {
        final L = palette[j];
        final isIntro = j == 0;
        final isHook = L == hook && !isIntro;
        final id = isIntro ? 'intro' : (isHook ? 'chorus_$L' : 'sec_$L');
        idOf[L] = id;
        final half = isIntro ? 0 : (isHook ? 1 : (j.isOdd ? 1 : 0));
        final energy = isIntro ? 0.4 : (isHook ? 1.0 : (0.6 + 0.12 * (j % 3)));
        sections.add(section(id, half * 4, energy,
            withLead: !isIntro,
            withCounter: isHook || j.isOdd,
            thin: isIntro));
      }
      sections.add(section('outro', 0, 0.5, withLead: false));
      final body = <String>[];
      for (final c in form.split('')) {
        final id = idOf[c];
        if (id != null && id != 'intro') body.add(id);
        if (body.length >= 14) break;
      }
      if (body.isEmpty) {
        body.add(idOf[palette.length > 1 ? palette[1] : palette[0]]!);
      }
      arrangement = ['intro', ...body, 'outro'];
    } else {
      sections = <Map<String, dynamic>>[
        section('intro', 0, 0.4, withLead: false, thin: true),
        section('verseA', 0, 0.65),
        section('chorus', 4, 1.0, withCounter: true),
        section('verseB', 0, 0.7),
        section('chorusFinal', 4, 1.0, withCounter: true),
        section('outro', 0, 0.5, withLead: false),
      ];
      arrangement = [
        'intro', 'verseA', 'chorus', 'verseB', 'chorus', 'chorusFinal', 'outro'
      ];
    }

    // Production from a RAG profile (matches a real song's effect balance).
    Map<String, dynamic> production = {};
    if (grooves.profiles.isNotEmpty) {
      production = Map<String, dynamic>.from(
          grooves.profiles[rng.nextInt(grooves.profiles.length)]);
    }

    return {
      'title': _title(mood, ex, rng),
      'concept': mood,
      'bpm': bpm.clamp(70, 190),
      'root': root,
      'scale': scale,
      if (ex['timbre'] != null) 'timbre': ex['timbre'],
      'production': production,
      'sections': sections,
      'arrangement': arrangement,
      // ~45% of tracks get a fresh Markov-generated melody (originality);
      // the rest keep the real exemplar lead (coherence). Both fit the chords.
      'markovLead': rng.nextDouble() < 0.45,
    };
  }

  List<List<num>> _voice(dynamic raw, int shift) {
    if (raw is! List) return const [];
    final out = <List<num>>[];
    for (final n in raw) {
      if (n is List && n.length >= 4) {
        out.add([
          (n[0] as num).toDouble(),
          (n[1] as num).toInt() + shift,
          (n[2] as num).toDouble(),
          (n[3] as num).toDouble(),
        ]);
      }
    }
    return out;
  }

  static const _moods = ['happy', 'tense', 'sad', 'calm'];
  String _randomMood(Random r) => _moods[r.nextInt(_moods.length)];

  String _title(String mood, Map<String, dynamic> ex, Random r) {
    const words = {
      'happy': ['Sunburst', 'Arcade Heart', 'Pixel Parade', 'Bright Circuit'],
      'tense': ['Red Alert', 'Overclock', 'Boss Rush', 'Static Storm'],
      'sad': ['Faded Save', 'Lonely Pixel', 'Last Continue', 'Blue Screen'],
      'calm': ['Drifting Bits', 'Soft Reset', 'Moonlit Map', 'Idle Dream'],
    };
    final list = words[mood] ?? const ['Chip Mood'];
    return list[r.nextInt(list.length)];
  }

  /// Analyse the photo's colours (no AI) into a mood quadrant PLUS continuous
  /// valence & arousal in 0..1: valence from brightness+warmth, arousal from
  /// saturation/brightness. The continuous values finely steer tempo & scale.
  Future<(String, double, double)> _analyzeImage(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes,
          targetWidth: 48, targetHeight: 48);
      final frame = await codec.getNextFrame();
      final data = await frame.image
          .toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return ('calm', 0.4, 0.3);
      final px = data.buffer.asUint8List();
      double rs = 0, gs = 0, bs = 0, satS = 0;
      var count = 0;
      for (var i = 0; i + 3 < px.length; i += 4) {
        final r = px[i] / 255.0, g = px[i + 1] / 255.0, b = px[i + 2] / 255.0;
        rs += r;
        gs += g;
        bs += b;
        final mx = max(r, max(g, b)), mn = min(r, min(g, b));
        satS += mx <= 0 ? 0 : (mx - mn) / mx;
        count++;
      }
      if (count == 0) return ('calm', 0.4, 0.3);
      final rA = rs / count, gA = gs / count, bA = bs / count;
      final bright = (rA + gA + bA) / 3.0;
      final warmth = rA - bA; // warm (red) vs cool (blue)
      final sat = satS / count;
      final valence = (0.5 + (bright - 0.42) * 1.1 + warmth * 1.6).clamp(0.0, 1.0);
      final arousal = (sat * 1.05 + (bright - 0.3) * 0.5).clamp(0.0, 1.0);
      const quad = {'11': 'happy', '01': 'tense', '00': 'sad', '10': 'calm'};
      final key = '${valence >= 0.5 ? 1 : 0}${arousal >= 0.5 ? 1 : 0}';
      return (quad[key] ?? 'calm', valence.toDouble(), arousal.toDouble());
    } catch (_) {
      return ('calm', 0.4, 0.3);
    }
  }

  Map<String, dynamic> _fallback(String mood, Random r) {
    final root = 57 + r.nextInt(8);
    return {
      'title': _title(mood, const {}, r),
      'concept': mood,
      'bpm': 120 + r.nextInt(40),
      'root': root,
      'scale': mood == 'happy' ? 'major' : 'minor',
      'production': const {},
      'sections': [
        {'id': 'intro', 'bars': 4, 'energy': 0.4, 'chords': [0, 0, 0, 0]},
        {'id': 'verse', 'bars': 4, 'energy': 0.7, 'chords': [0, 5, 3, 4]},
        {'id': 'chorus', 'bars': 4, 'energy': 1.0, 'chords': [3, 4, 0, 5]},
        {'id': 'outro', 'bars': 4, 'energy': 0.5, 'chords': [0, 0, 0, 0]},
      ],
      'arrangement': ['intro', 'verse', 'chorus', 'verse', 'chorus', 'outro'],
    };
  }
}
