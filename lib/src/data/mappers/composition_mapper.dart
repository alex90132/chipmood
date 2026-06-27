import '../../domain/entities/composition.dart';
import '../../domain/entities/envelope.dart';
import '../../domain/entities/instrument.dart';
import '../../domain/entities/note.dart';
import '../../domain/entities/pattern.dart';
import '../../domain/entities/waveform.dart';

/// Converts between the domain [Composition] and the tracker-style JSON
/// contract shared by the AI composer and the Rust engine. Parsing is lenient.
class CompositionMapper {
  const CompositionMapper();

  // ---- JSON (AI output) -> domain -------------------------------------

  Composition fromJson(Map<String, dynamic> json, {double targetSeconds = 120}) {
    return Composition(
      title: _nonEmpty(json['title'], 'Untitled'),
      bpm: _toDouble(json['bpm'], 120),
      sampleRate: _toInt(json['sample_rate'], 44100),
      masterVolume: _toDouble(json['master_volume'], 0.85),
      delayWet: _toDouble(json['delay_wet'], 0.0),
      targetSeconds: _toDouble(json['target_seconds'], targetSeconds),
      instruments: _list(json['instruments'])
          .map(_instrumentFromJson)
          .toList(growable: false),
      patterns:
          _list(json['patterns']).map(_patternFromJson).toList(growable: false),
      arrangement: ((json['arrangement'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList(growable: false),
      sampleBank: (json['sample_bank'] as String?),
    );
  }

  Instrument _instrumentFromJson(Map<String, dynamic> json) {
    return Instrument(
      id: _nonEmpty(json['id'], 'inst'),
      waveform: Waveform.fromWire((json['waveform'] as String?) ?? 'square'),
      duty: _toDouble(json['duty'], 0.5),
      volume: _toDouble(json['volume'], 0.8),
      pan: _toDouble(json['pan'], 0.0),
      glide: _toDouble(json['glide'], 0.0),
      drive: _toDouble(json['drive'], 0.0),
      tone: _toDouble(json['tone'], 0.5),
      crush: _toDouble(json['crush'], 0.0),
      trem: _toDouble(json['trem'], 0.0),
      cutoff: _toDouble(json['cutoff'], 1.0),
      resonance: _toDouble(json['resonance'], 0.0),
      filterEnv: _toDouble(json['filter_env'], 0.0),
      envelope: _envelopeFromJson(json['envelope']),
      sample: json['sample'] as String?,
    );
  }

  Envelope _envelopeFromJson(dynamic json) {
    if (json is! Map<String, dynamic>) return Envelope.defaults;
    return Envelope(
      attack: _toDouble(json['attack'], 0.005),
      decay: _toDouble(json['decay'], 0.04),
      sustain: _toDouble(json['sustain'], 0.7),
      release: _toDouble(json['release'], 0.08),
    );
  }

  Pattern _patternFromJson(Map<String, dynamic> json) {
    return Pattern(
      id: _nonEmpty(json['id'], 'P'),
      lengthBeats: _toDouble(json['length_beats'] ?? json['len'], 0),
      tracks: _list(json['tracks'])
          .map(_patternTrackFromJson)
          .toList(growable: false),
    );
  }

  PatternTrack _patternTrackFromJson(Map<String, dynamic> json) {
    final raw = (json['notes'] as List?) ?? const [];
    return PatternTrack(
      instrumentId: _nonEmpty(json['instrument'] ?? json['ins'], 'inst'),
      notes: raw.map(_noteFrom).whereType<Note>().toList(growable: false),
    );
  }

  /// Accepts either the compact array form `[start, pitch, dur, vel?]` (token
  /// efficient, used by the AI) or the verbose object form.
  Note? _noteFrom(dynamic n) {
    if (n is List && n.length >= 3) {
      return Note(
        start: _toDouble(n[0], 0),
        pitch: _toInt(n[1], -1),
        duration: _toDouble(n[2], 0),
        velocity: n.length >= 4 ? _toDouble(n[3], 1.0) : 1.0,
      );
    }
    if (n is Map) {
      return Note(
        pitch: _toInt(n['pitch'], -1),
        start: _toDouble(n['start'], 0),
        duration: _toDouble(n['duration'], 0),
        velocity: _toDouble(n['velocity'], 1.0),
        arp: ((n['arp'] as List?) ?? const [])
            .map((e) => _toInt(e, 0))
            .toList(growable: false),
        slide: _toDouble(n['slide'], 0),
        vib: _toDouble(n['vib'], 0),
        retrig: _toInt(n['retrig'], 0),
        delay: _toDouble(n['delay'], 0),
      );
    }
    return null;
  }

  // ---- domain -> JSON (for the Rust engine) ---------------------------

  Map<String, dynamic> toJson(Composition c) {
    return {
      'title': c.title,
      'bpm': c.bpm,
      'sample_rate': c.sampleRate,
      'master_volume': c.masterVolume,
      'delay_wet': c.delayWet,
      'target_seconds': c.targetSeconds,
      if (c.sampleBank != null) 'sample_bank': c.sampleBank,
      'instruments': c.instruments.map(_instrumentToJson).toList(),
      'patterns': c.patterns.map(_patternToJson).toList(),
      'arrangement': c.arrangement,
    };
  }

  Map<String, dynamic> _instrumentToJson(Instrument i) {
    return {
      'id': i.id,
      'waveform': i.waveform.wire,
      'duty': i.duty,
      'volume': i.volume,
      'pan': i.pan,
      'glide': i.glide,
      'drive': i.drive,
      'tone': i.tone,
      'crush': i.crush,
      'trem': i.trem,
      'cutoff': i.cutoff,
      'resonance': i.resonance,
      'filter_env': i.filterEnv,
      if (i.sample != null) 'sample': i.sample,
      'envelope': {
        'attack': i.envelope.attack,
        'decay': i.envelope.decay,
        'sustain': i.envelope.sustain,
        'release': i.envelope.release,
      },
    };
  }

  Map<String, dynamic> _patternToJson(Pattern p) {
    return {
      'id': p.id,
      'length_beats': p.lengthBeats,
      'tracks': p.tracks
          .map((t) => {
                'instrument': t.instrumentId,
                'notes': t.notes
                    .map((n) => {
                          'pitch': n.pitch,
                          'start': n.start,
                          'duration': n.duration,
                          'velocity': n.velocity,
                          if (n.arp.isNotEmpty) 'arp': n.arp,
                          if (n.slide != 0) 'slide': n.slide,
                          if (n.vib != 0) 'vib': n.vib,
                          if (n.retrig != 0) 'retrig': n.retrig,
                          if (n.delay != 0) 'delay': n.delay,
                        })
                    .toList(),
              })
          .toList(),
    };
  }

  // ---- helpers --------------------------------------------------------

  static List<Map<String, dynamic>> _list(dynamic v) =>
      ((v as List?) ?? const []).whereType<Map<String, dynamic>>().toList();

  static String _nonEmpty(dynamic v, String fallback) {
    if (v is String && v.trim().isNotEmpty) return v;
    return fallback;
  }

  static double _toDouble(dynamic v, double fallback) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? fallback;
    return fallback;
  }

  static int _toInt(dynamic v, int fallback) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? fallback;
    return fallback;
  }
}
