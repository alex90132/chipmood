import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart' show rootBundle;

/// Retrieves REAL melodies from two datasets — NES-MDB chiptunes (gritty
/// 4-channel originals) and a large multi-track General-MIDI set (rich melodic,
/// harmonic and rhythmic vocabulary across genres) — all normalized to the key
/// of C and tagged by mood. They're formatted as few-shot examples so the
/// composer writes original tracks grounded in genuine music.
class NesRag {
  List<Map<String, dynamic>>? _all;
  List<String>? _structures;

  Future<List<Map<String, dynamic>>> _load(String asset, String source) async {
    try {
      final raw = await rootBundle.loadString(asset);
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      for (final e in list) {
        e['source'] = e['source'] ?? source;
      }
      return list;
    } catch (_) {
      return const [];
    }
  }

  Future<void> _ensure() async {
    if (_all != null) return;
    final nes = await _load('assets/rag/nes_exemplars.json', 'nes');
    final vgm = await _load('assets/rag/vgm_exemplars.json', 'vgm');
    // The real Unreal/UT99 soundtrack — the user's gold standard (16-32 voices,
    // through-composed forms, beautiful demoscene leads). Loaded as a premium
    // source so both the few-shot and the offline composer lean on it.
    final ut = await _load('assets/rag/ut_exemplars.json', 'ut');
    // POP909 — real pop chord progressions + a genuine secondary line (counter);
    // EMOPIA — solo-piano clips with PRECISE valence/arousal mood labels. Both
    // widen the pool, especially the happy/tense moods the UT set is thin on.
    final pop = await _load('assets/rag/pop_exemplars.json', 'pop');
    final emo = await _load('assets/rag/emo_exemplars.json', 'emo');
    // VGMIDI — solo-piano arrangements of video-game soundtracks (on-theme
    // game-music vocabulary).
    final vg = await _load('assets/rag/vg_exemplars.json', 'vg');
    // YM2413-MDB — 80s FM (OPLL) video-game music with 4-quadrant emotion
    // labels, mined from the 6.4 GB Zenodo archive. Adds expressive FM-era
    // game leads + precise mood tags. source='ym'.
    final ym = await _load('assets/rag/ym_exemplars.json', 'ym');
    _all = [...nes, ...vgm, ...ut, ...pop, ...emo, ...vg, ...ym];
    try {
      final raw = await rootBundle.loadString('assets/rag/ut_structures.json');
      _structures = (jsonDecode(raw) as List).cast<String>();
    } catch (_) {
      _structures = const [];
    }
  }

  /// A real through-composed song form distilled from the UT99 order lists
  /// (e.g. "ABCBDCEF..."), so arrangements get genuine, varied structure rather
  /// than a fixed verse/chorus loop. Returns null if none are available.
  Future<String?> pickStructure({Random? rng}) async {
    await _ensure();
    final s = _structures ?? const [];
    if (s.isEmpty) return null;
    final r = rng ?? Random();
    return s[r.nextInt(s.length)];
  }

  /// Pick ONE full real exemplar (all voices) for the given mood — used by the
  /// offline composer that builds tracks straight from the RAG, no AI.
  /// [prefer] biases the choice toward given sources in priority order (e.g.
  /// ['ut'] to favour the Unreal soundtrack) while still falling back.
  Future<Map<String, dynamic>?> pickFull(String mood,
      {Random? rng, List<String>? prefer}) async {
    await _ensure();
    final all = _all ?? const [];
    if (all.isEmpty) return null;
    final r = rng ?? Random();
    final byMood = all.where((e) => e['mood'] == mood).toList();
    final pool = byMood.isNotEmpty ? byMood : List.of(all);
    if (prefer != null) {
      for (final src in prefer) {
        final sub = pool.where((e) => e['source'] == src).toList();
        if (sub.isNotEmpty) return sub[r.nextInt(sub.length)];
      }
    }
    return pool[r.nextInt(pool.length)];
  }

  /// Tiny "hit phrase" cards for the clipboard AI remix prompt: 1 bar of a
  /// real pro lead (+ optional bass/drums), so the chat model hears craft
  /// without dumping a whole song. Prefer UT / NES / YM when available.
  Future<List<Map<String, dynamic>>> pickHitPhrases({
    int count = 2,
    String? mood,
    Random? rng,
  }) async {
    await _ensure();
    final all = _all ?? const [];
    if (all.isEmpty) return const [];
    final r = rng ?? Random();
    var pool = mood == null
        ? List.of(all)
        : all.where((e) => e['mood'] == mood).toList();
    if (pool.isEmpty) pool = List.of(all);

    // Prefer sources that sound like "hits" the user cares about.
    const prefer = ['ut', 'nes', 'ym', 'vg', 'vgm', 'pop'];
    final ranked = <Map<String, dynamic>>[];
    for (final src in prefer) {
      ranked.addAll(pool.where((e) => e['source'] == src));
    }
    for (final e in pool) {
      if (!ranked.contains(e)) ranked.add(e);
    }
    ranked.shuffle(r);

    final out = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final e in ranked) {
      if (out.length >= count) break;
      final card = _hitCard(e);
      if (card == null) continue;
      final sig = '${card['mood']}|${card['bpm']}|${card['lead']}';
      if (!seen.add(sig)) continue;
      out.add(card);
    }
    return out;
  }

  /// One bar of lead (re-zeroed) + a few bass/drum hits — small enough for chat.
  Map<String, dynamic>? _hitCard(Map<String, dynamic> e) {
    final lead = _sliceBar(e['lead'], maxNotes: 10);
    if (lead == null || lead.length < 3) return null;
    final bass = _sliceBar(e['bass'], maxNotes: 6);
    final drums = _sliceBar(e['drums'], maxNotes: 8);
    final chords = (e['chords'] as List?) ?? const [];
    return {
      'mood': e['mood'],
      'bpm': e['bpm'],
      'scale': e['scale'],
      if (e['timbre'] != null) 'timbre': e['timbre'],
      'from': e['source'] ?? 'pro',
      if (chords.isNotEmpty) 'chord': (chords.first as num).toInt(),
      'lead': lead,
      if (bass != null && bass.isNotEmpty) 'bass': bass,
      if (drums != null && drums.isNotEmpty) 'drums': drums,
    };
  }

  /// First bar (beats 0..4) of a voice, re-zeroed; falls back to first N notes.
  List<List<num>>? _sliceBar(dynamic raw, {int maxNotes = 10}) {
    if (raw is! List || raw.isEmpty) return null;
    final inBar = <List<num>>[];
    final any = <List<num>>[];
    for (final n in raw) {
      if (n is! List || n.length < 3) continue;
      final start = (n[0] as num).toDouble();
      final pitch = (n[1] as num).toInt();
      final dur = (n[2] as num).toDouble();
      final vel = n.length >= 4 ? (n[3] as num).toDouble() : 0.9;
      final row = <num>[
        double.parse(start.toStringAsFixed(2)),
        pitch,
        double.parse(dur.toStringAsFixed(2)),
        double.parse(vel.clamp(0.0, 1.0).toStringAsFixed(2)),
      ];
      any.add(row);
      if (start >= 0 && start < 4.0) {
        inBar.add([
          double.parse(start.toStringAsFixed(2)),
          pitch,
          double.parse(dur.toStringAsFixed(2)),
          row[3],
        ]);
      }
    }
    final pick = inBar.length >= 3 ? inBar : any;
    if (pick.isEmpty) return null;
    // Re-zero so the bar starts at 0 (easier for the model to imitate rhythm).
    final t0 = pick.first[0].toDouble();
    return [
      for (final n in pick.take(maxNotes))
        <num>[
          double.parse((n[0].toDouble() - t0).clamp(0.0, 8.0).toStringAsFixed(2)),
          n[1],
          n[2],
          n[3],
        ]
    ];
  }

  /// Returns a few-shot block: a diverse set of real melodies covering each
  /// mood and BOTH datasets, so the model has broad vocabulary (chiptune grit
  /// + rich multi-track arranging) for whatever the photo's mood is.
  Future<String> fewShot() async {
    await _ensure();
    final all = _all ?? const [];
    if (all.isEmpty) return '';
    final rng = Random();
    final moods = ['happy', 'tense', 'sad', 'calm'];

    Map<String, dynamic>? pick(String mood, String source) {
      final pool =
          all.where((e) => e['mood'] == mood && e['source'] == source).toList();
      if (pool.isEmpty) return null;
      return pool[rng.nextInt(pool.length)];
    }

    Map<String, dynamic>? pickAny(String mood, List<String> order) {
      for (final s in order) {
        final e = pick(mood, s);
        if (e != null) return e;
      }
      return null;
    }

    final picks = <Map<String, dynamic>>[];
    // The Unreal/UT99 soundtrack ('ut') is the gold standard, so it is the
    // FIRST choice for every mood; nes & vgm fill in for breadth and whenever a
    // UT mood pool is empty. This keeps the block grounded in the pro tracks
    // the user loves while still rotating for variety.
    const priority = [
      ['ut', 'vg', 'pop', 'emo', 'ym', 'nes', 'vgm'],
      ['emo', 'ut', 'ym', 'pop', 'vg', 'vgm', 'nes'],
      ['pop', 'vg', 'ym', 'nes', 'ut', 'emo', 'vgm'],
      ['vgm', 'emo', 'vg', 'ym', 'ut', 'pop', 'nes'],
    ];
    for (var i = 0; i < moods.length; i++) {
      final e = pickAny(moods[i], priority[i]);
      if (e != null) picks.add(e);
    }
    if (picks.isEmpty) {
      all.shuffle(rng);
      picks.addAll(all.take(4));
    }

    final buf = StringBuffer(
      'REFERENCE TRACKS by PROFESSIONAL composers (real NES & game music, '
      'normalized to key C). These are your GOLD STANDARD — your composition '
      'must live up to their craft. STUDY them closely: how the LEAD builds a '
      'singable, developing melody; how HARMONY and COUNTER move under it; how '
      'the BASS walks with the groove; how the DRUMS sit; their tempo, scale, '
      'chord motion, phrasing, density and feel.\n'
      'PICK the ONE whose mood best fits the photo and let it LEAD your choices '
      '— take its tempo (bpm), scale, rhythmic density, groove and phrase shape, '
      'and compose at that level of craftsmanship. Write your OWN original notes '
      'in that spirit (do NOT copy theirs). A different reference is drawn each '
      'time, so each track must come out clearly different in tempo, key, groove '
      'and structure — never a fixed formula.\n',
    );
    for (var i = 0; i < picks.length; i++) {
      final e = picks[i];
      final m = <String, dynamic>{
        'mood': e['mood'],
        'bpm': e['bpm'],
        'scale': e['scale'],
        if (e['timbre'] != null) 'timbre': e['timbre'],
        'chords': e['chords'],
        'lead': e['lead'],
        'harmony': e['harmony'],
      };
      final counter = e['counter'];
      if (counter is List && counter.isNotEmpty) m['counter'] = counter;
      m['bass'] = e['bass'];
      m['drums'] = e['drums'];
      buf.writeln('REFERENCE ${i + 1} (mood=${e['mood']}, bpm=${e['bpm']}, '
          'scale=${e['scale']}): ${jsonEncode(m)}');
    }
    // Real through-composed FORMS distilled from the Unreal/UT99 order lists
    // (each letter = a distinct section). They show how the pros develop a
    // track — long, evolving, lightly repeating — never one looping idea.
    final forms = _structures ?? const [];
    if (forms.isNotEmpty) {
      final sample = (List.of(forms)..shuffle(rng)).take(3).toList();
      buf.writeln(
        'REAL SONG FORMS from these pros (letters = distinct sections; build '
        'an intro, a developing body of several different sections, and an '
        'ending — repeat sparingly like they do): ${sample.join("  ")}',
      );
    }
    return buf.toString();
  }
}
