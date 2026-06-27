import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

/// An order-2 Markov model of melody (scale degrees) learned from every RAG
/// exemplar lead, plus a bank of real 1-bar rhythms. The arranger uses it to
/// generate NEW, in-style, chord-anchored melodies instead of replaying phrases
/// verbatim — more originality and per-track variation, still musical.
class MarkovModel {
  final int degLo;
  final int degHi;

  /// "a,b" -> list of [degree, weight] continuations.
  final Map<String, List<List<num>>> trans;

  /// [a, b, weight] starting pairs.
  final List<List<int>> starts;

  /// Real 1-bar rhythms: each is a list of [positionBeats, durationBeats].
  final List<List<List<double>>> rhythms;

  const MarkovModel({
    required this.degLo,
    required this.degHi,
    required this.trans,
    required this.starts,
    required this.rhythms,
  });

  bool get ready => trans.isNotEmpty && rhythms.isNotEmpty && starts.isNotEmpty;

  static const empty =
      MarkovModel(degLo: -10, degHi: 17, trans: {}, starts: [], rhythms: []);
}

class MarkovLibrary {
  MarkovModel? _model;

  Future<MarkovModel> load() async {
    if (_model != null) return _model!;
    try {
      final raw = await rootBundle.loadString('assets/rag/markov.json');
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final trans = <String, List<List<num>>>{};
      (m['trans'] as Map<String, dynamic>).forEach((k, v) {
        trans[k] = (v as List)
            .map<List<num>>((e) => (e as List).map((x) => x as num).toList())
            .toList();
      });
      final starts = ((m['starts'] as List?) ?? const [])
          .map<List<int>>((e) => (e as List).map((x) => (x as num).toInt()).toList())
          .toList();
      final rhythms = ((m['rhythms'] as List?) ?? const [])
          .map<List<List<double>>>((bar) => (bar as List)
              .map<List<double>>(
                  (p) => (p as List).map((x) => (x as num).toDouble()).toList())
              .toList())
          .toList();
      _model = MarkovModel(
        degLo: (m['deg_lo'] as num?)?.toInt() ?? -10,
        degHi: (m['deg_hi'] as num?)?.toInt() ?? 17,
        trans: trans,
        starts: starts,
        rhythms: rhythms,
      );
    } catch (_) {
      _model = MarkovModel.empty;
    }
    return _model!;
  }
}
