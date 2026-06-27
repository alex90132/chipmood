import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart' hide ProgressCallback;

import '../../core/config/app_config.dart';
import '../../core/error/failures.dart';
import '../../domain/entities/compose_request.dart';
import '../../domain/repositories/composer_repository.dart';
import '../knowledge/track_dna.dart';

/// Talks to OpenRouter (streaming) and returns a compact "song plan" JSON:
/// key + chord progression per section + the lead melody. The heavy lifting
/// (arpeggios, bass, drums) is done by the ProceduralArranger, so the model's
/// output stays small — fast to generate yet musically rich after arranging.
class OpenRouterDataSource {
  final Dio _dio;
  final String Function() _apiKey;
  final String Function() _model;

  OpenRouterDataSource(this._dio, this._apiKey, this._model);

  Future<Map<String, dynamic>> composeJson(
    ComposeRequest request, {
    ProgressCallback? onProgress,
    String reference = '',
  }) async {
    final key = _apiKey().trim();
    if (key.isEmpty) {
      throw const ConfigFailure(
        'OpenRouter API key is not set. Add it in Settings.',
      );
    }

    final body = {
      'model': _model(),
      'response_format': {'type': 'json_object'},
      'temperature': 1.0,
      'max_tokens': 12000,
      'stream': true,
      if (AppConfig.disableReasoning) 'reasoning': {'enabled': false},
      'messages': [
        {'role': 'system', 'content': _systemPrompt},
        {'role': 'user', 'content': _userContent(request, reference)},
      ],
    };

    try {
      final response = await _dio.post<ResponseBody>(
        '${AppConfig.openRouterBaseUrl}/chat/completions',
        data: body,
        options: Options(
          responseType: ResponseType.stream,
          headers: {
            'Authorization': 'Bearer $key',
            'Content-Type': 'application/json',
            'Accept': 'text/event-stream',
            'HTTP-Referer': AppConfig.appReferer,
            'X-Title': AppConfig.appTitle,
          },
        ),
      );
      final content = await _readStream(response.data!, onProgress);
      onProgress?.call(1.0);
      return _decodeJsonObject(content);
    } on DioException catch (e) {
      throw ComposerFailure(_describeDioError(e));
    }
  }

  Future<String> _readStream(ResponseBody body, ProgressCallback? onProgress) async {
    final content = StringBuffer();
    var pending = '';
    await for (final bytes in body.stream) {
      pending += utf8.decode(bytes, allowMalformed: true);
      final lines = pending.split('\n');
      pending = lines.removeLast();
      for (final raw in lines) {
        final line = raw.trim();
        if (line.isEmpty || line.startsWith(':') || !line.startsWith('data:')) {
          continue;
        }
        final data = line.substring(5).trim();
        if (data == '[DONE]') break;
        try {
          final delta = (jsonDecode(data)['choices'] as List?)?.first;
          final piece = (delta?['delta']?['content']) as String?;
          if (piece != null) content.write(piece);
        } catch (_) {}
      }
      final n = content.length;
      onProgress?.call((n / (n + 1500)).clamp(0.0, 0.98));
    }
    if (content.isEmpty) {
      throw const ComposerFailure('OpenRouter returned an empty response.');
    }
    return content.toString();
  }

  Map<String, dynamic> _decodeJsonObject(String content) {
    String text = content.trim();
    final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```', multiLine: true);
    final m = fence.firstMatch(text);
    if (m != null) text = m.group(1)!.trim();
    if (!text.startsWith('{')) {
      final s = text.indexOf('{');
      final e = text.lastIndexOf('}');
      if (s != -1 && e > s) text = text.substring(s, e + 1);
    }
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) return decoded;
      throw const CompositionParseFailure('Expected a JSON object.');
    } on FormatException catch (e) {
      throw CompositionParseFailure('Could not parse AI output: ${e.message}');
    }
  }

  String _describeDioError(DioException e) {
    final status = e.response?.statusCode;
    if (status == 401) return 'OpenRouter rejected the API key (401).';
    if (status == 429) return 'Rate limited by OpenRouter (429). Try later.';
    if (status != null) return 'OpenRouter error $status.';
    return 'Network error contacting OpenRouter: ${e.message}';
  }

  static const String _systemPrompt = '''
You are a brilliant chiptune composer-producer. From the attached photo you
create an ORIGINAL, complete piece of music. Mood, genre, key, tempo, structure
and sound design are entirely YOUR decisions — this prompt only describes WHAT
you can control and HOW the engine renders it; the art is up to you. Output ONLY
one JSON object — no prose, no markdown.

YOUR ENSEMBLE — eight NES/16-bit voices:
lead (main melody), harmony (support), counter (optional 2nd melody), bass,
pad (sustained chords), arp (fast arpeggios), drums (kick 36 / snare 38 /
tom 40 / hat 42), perc (extra hats). You write the notes for lead, harmony,
counter, bass and drums; the engine builds pad, arp and perc from your chords.
Each note is an ARRAY [start, pitch, duration, velocity] in beats; pitch = MIDI
(60 = C4).

HOW THE ENGINE PERFORMS YOUR SONG:
- It plays "arrangement" as a real track: the FIRST section is the intro and the
  LAST is the outro (each once); the middle sections loop to fill the duration.
- Bass & drums are reinforced so the pulse never drops out.
- It applies per-voice sound design from "production": overdrive, bit-crush,
  portamento, vibrato, retrigger, a resonant filter with envelope, tremolo, a
  tempo-synced echo, plus reverb and mastering.

YOUR PRIMARY GUIDE is the set of REFERENCE TRACKS provided below — real music by
professional composers. Let them set the bar: learn their melodic phrasing,
harmonic motion, basslines, grooves, density and arrangement, and compose to
that standard. They lead your musical decisions; the photo sets the mood.

JSON schema:
{
  "title": string,
  "concept": string,             // one-line emotional read of the photo that drives the music
  "bpm": number,                 // TAKE this from the chosen reference's bpm
  "root": integer,               // MIDI tonic, 57-64 (e.g. 60 = C4)
  "scale": "major"|"minor"|"dorian"|"mixolydian"|"phrygian"|"harmonicminor",
  "timbre": "square"|"saw"|"brass"|"string"|"organ"|"reed"|"mellow"|"bright",
                                 // lead tone colour — from the reference / photo mood
  "production": {                // HOW it should SOUND — choose tastefully (see SOUND DESIGN)
    "leadDrive": 0..1,           // grit/overdrive on the lead
    "leadCrush": 0..1,           // lo-fi bit-crush on the lead
    "leadGlide": 0..1,           // portamento (pitch slides) on the lead
    "bassWave": "triangle"|"pulse"|"sawtooth",
    "bassDrive": 0..1,
    "drumsTone": 0..1,           // 0 = soft hiss .. 1 = metallic ring
    "percTone": 0..1,            // shaker/hat brightness
    "padWave": "triangle"|"sine"|"pulse",
    "padTrem": 0..1,             // tremolo wobble on the pad
    "arpWave": "pulse"|"square",
    "arpTrem": 0..1,
    "delay": 0..1,               // tempo-synced echo/space on the mix
    "cutoff": 0.05..1,           // resonant low-pass (1=open, lower=darker)
    "resonance": 0..1,           // filter emphasis/peak
    "filterEnv": 0..1            // filter sweep amount (pluck/wow on lead+bass)
  },
  "sections": [
    {
      "id": string,              // intro|verseA|verseB|preChorus|chorus|bridge|chorusFinal|outro
      "bars": integer,           // usually 4
      "energy": number,          // 0.3 (sparse intro/verse) .. 1.0 (chorus)
      "chords": [integer],       // diatonic scale degrees, ONE per bar (0=I..6=vii)
      "lead":    [[start,pitch,dur,vel]],
      "harmony": [[start,pitch,dur,vel]],
      "counter": [[start,pitch,dur,vel]],   // optional 2nd melody (choruses/bridges)
      "bass":    [[start,pitch,dur,vel]],
      "drums":   [[start,pitch,dur,vel]]
    }
  ],
  "arrangement": [ "ids in song order" ]
}

WHAT EACH CONTROL DOES (use any of it, however you like):
- root / scale / bpm: tonic, mode and tempo.
- timbre: the lead's tone colour (square, saw, brass, string, organ, reed,
  mellow, bright).
- production.leadDrive / leadCrush: overdrive and lo-fi crush on the lead.
- production.bassWave / bassDrive: the bass waveform and its grit.
- production.cutoff / resonance / filterEnv: a resonant low-pass and how far it
  sweeps per note (the electronic "pluck / wow"), on lead and bass.
- production.drumsTone / percTone: how bright/metallic the drums read.
- production.padWave / padTrem and arpWave / arpTrem: pad & arp tone and wobble.
- production.delay: tempo-synced echo / sense of space.
- each section's energy (0..1): how full and loud the engine renders it.
- each section's chords: diatonic scale degrees, one per bar.
- per note you may also set: arp (semitone offsets = a chord on one channel),
  slide (portamento semitones), vib (vibrato), retrig (stutter), delay (lay-back).


THE ONLY HARD RULES (everything else is your artistic choice):
- Return ONE valid JSON object matching the schema; notes are arrays.
- bass and drums appear in EVERY bar of EVERY section (so nothing falls silent).
- Keep pitches musical: lead/harmony ~48-84, bass ~28-52, drums 36/38/40/42.
- Let the professional REFERENCE TRACKS guide your craft (melody, harmony, bass,
  groove, density, arrangement); the photo sets the mood. Never copy their
  notes — compose your own at their level.

Output ONLY the JSON.
''';

  String _userPrompt(ComposeRequest r, String reference) {
    final lines = <String>[
      r.hasImage
          ? 'Look at the attached photo. Compose an ORIGINAL chiptune track '
              'whose mood, energy and colors match the scene.'
          : 'Compose an original chiptune track.',
      if (r.prompt.trim().isNotEmpty) 'Extra direction: ${r.prompt.trim()}',
      'Full creative freedom over key, tempo, chords and melody. Make a '
          'memorable, emotional masterpiece with a strong, singable chorus hook.',
      'Target ~${r.targetSeconds.round()}s total (intro once, body develops, '
          'outro once).',
      '',
      reference.trim().isNotEmpty ? reference : buildReference(r.prompt),
      '',
      'Now compose. Let the photo set the mood and the professional reference '
          'tracks guide your craft — match their melodic and rhythmic quality. '
          'Use the controls and voices however you see fit. Return ONLY the JSON.',
    ];
    return lines.join('\n');
  }

  dynamic _userContent(ComposeRequest r, String reference) {
    final text = _userPrompt(r, reference);
    if (!r.hasImage) return text;
    final b64 = base64Encode(r.imageBytes!);
    return [
      {'type': 'text', 'text': text},
      {
        'type': 'image_url',
        'image_url': {'url': 'data:image/jpeg;base64,$b64'},
      },
    ];
  }
}
