import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'features/read_aloud/domain/text_chunk.dart';
import 'mp3.dart';
import 'features/read_aloud/domain/word_timing.dart';

class SpeechException implements Exception {
  const SpeechException(this.message, {this.status});
  final String message;

  /// The HTTP status behind the error, when the server answered at all.
  final int? status;
  @override
  String toString() => message;
}

/// A user-supplied key is sent only to the explicitly configured HTTPS endpoint.
/// No keys, input text, response bodies or headers are logged or persisted.
class SpeechApi {
  SpeechApi(this.client);
  final http.Client client;

  Future<Uint8List> generate({
    required String text,
    required String endpoint,
    required String apiKey,
    required String model,
    required String voice,
    double speed = 1,
    void Function(int, int)? onProgress,
  }) async {
    final uri = _checkEndpoint(endpoint);
    if (apiKey.trim().isEmpty || model.trim().isEmpty || voice.trim().isEmpty) {
      throw const SpeechException('Enter your API key, model, and voice.');
    }
    if (text.trim().isEmpty) {
      throw const SpeechException('Add some text first.');
    }
    final chunks = chunkText(text);
    final parts = <Uint8List>[];
    for (var i = 0; i < chunks.length; i++) {
      onProgress?.call(i, chunks.length);
      final request = http.Request('POST', uri)
        ..followRedirects = false
        ..headers.addAll({
          'Authorization': 'Bearer ${apiKey.trim()}',
          'Content-Type': 'application/json',
        })
        ..body = jsonEncode({
          'model': model.trim(),
          'voice': voice.trim(),
          'input': chunks[i].text,
          'response_format': 'mp3',
          'speed': speed,
        });
      final response = await (() async {
        final streamed = await client.send(request);
        return http.Response.fromStream(streamed);
      })().timeout(const Duration(seconds: 90));
      if (response.statusCode != 200) {
        final message = switch (response.statusCode) {
          401 ||
          403 => 'The provider rejected this API key or its permissions.',
          429 => 'The provider rate limit or account quota was reached.',
          >= 300 && < 400 =>
            'The endpoint redirected the request. Enter its final HTTPS address.',
          _ =>
            'Speech generation failed (HTTP ${response.statusCode}). Check your endpoint, model, and voice.',
        };
        throw SpeechException(message, status: response.statusCode);
      }
      if (!_isMp3(response.bodyBytes)) {
        throw const SpeechException(
          'The provider did not return MP3 audio. Check its speech settings.',
        );
      }
      parts.add(response.bodyBytes);
    }
    onProgress?.call(chunks.length, chunks.length);
    return concatMp3(parts);
  }

  /// Kokoro-FastAPI's captioned endpoint returns both the audio and timing.
  Future<({Uint8List audio, List<WordTiming> timings})> captioned({
    required String endpoint,
    required String apiKey,
    required String voice,
    required String text,
    required bool useMarkup,
  }) async {
    final speech = _checkEndpoint(endpoint);
    final request = http.Request('POST', captionedEndpoint(speech))
      ..followRedirects = false
      ..headers.addAll({
        'Authorization': 'Bearer ${apiKey.trim()}',
        'Content-Type': 'application/json',
      })
      ..body = jsonEncode({
        'model': 'kokoro',
        'input': text,
        'voice': voice,
        'speed': 1,
        'response_format': 'mp3',
        'stream': false,
        'return_timestamps': true,
        'allow_voice_tags': true,
      });
    final response = await (() async {
      return http.Response.fromStream(await client.send(request));
    })().timeout(const Duration(seconds: 90));
    if (!useMarkup &&
        (response.statusCode == 404 || response.statusCode == 405)) {
      return (
        audio: await generate(
          text: text,
          endpoint: endpoint,
          apiKey: apiKey,
          model: 'kokoro',
          voice: voice,
        ),
        timings: const <WordTiming>[],
      );
    }
    if (response.statusCode != 200) {
      throw SpeechException(
        'Kokoro could not generate audio (HTTP ${response.statusCode}).',
        status: response.statusCode,
      );
    }
    final Map<Object?, Object?> body;
    final Uint8List audio;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map || decoded['audio'] is! String) {
        throw const FormatException();
      }
      body = decoded;
      audio = base64Decode(decoded['audio'] as String);
    } on FormatException {
      throw const SpeechException('Kokoro returned no audio.');
    }
    if (!_isMp3(audio)) {
      throw const SpeechException('Kokoro returned invalid MP3 audio.');
    }
    final raw = body['timestamps'];
    final timings = [
      for (final item in raw is List ? raw : const [])
        ?WordTiming.fromJson(item),
    ]..sort((a, b) => a.start.compareTo(b.start));
    return (audio: audio, timings: timings);
  }

  /// Voice ids from an OpenAI-compatible server's `/audio/voices`, next to the
  /// speech endpoint. Kokoro-FastAPI has it; OpenAI itself does not.
  Future<List<String>> voices({
    required String endpoint,
    required String apiKey,
  }) async {
    final speech = _checkEndpoint(endpoint);
    if (apiKey.trim().isEmpty) {
      throw const SpeechException('Enter your key first.');
    }
    if (!speech.path.endsWith('/audio/speech')) {
      throw const SpeechException(
        'This endpoint has no voice list. Type a voice instead.',
      );
    }
    final uri = speech.replace(
      path: speech.path.replaceFirst(
        RegExp(r'/audio/speech$'),
        '/audio/voices',
      ),
    );
    final request = http.Request('GET', uri)
      ..followRedirects = false
      ..headers['Authorization'] = 'Bearer ${apiKey.trim()}';
    final response = await (() async {
      final streamed = await client.send(request);
      return http.Response.fromStream(streamed);
    })().timeout(const Duration(seconds: 20));
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw SpeechException(
        'The server rejected this key.',
        status: response.statusCode,
      );
    }
    if (response.statusCode != 200) {
      throw SpeechException(
        'Could not load voices (HTTP ${response.statusCode}). Type a voice instead.',
      );
    }
    try {
      final body = jsonDecode(response.body);
      final list = body is Map ? body['voices'] : null;
      // Older Kokoro releases list bare ids; newer ones list `{ id, … }`.
      final ids = <String>[
        for (final v in list is List ? list : const [])
          if (v is String)
            v
          else if (v is Map && v['id'] is String)
            v['id'] as String,
      ]..sort();
      if (ids.isEmpty) throw const FormatException();
      return ids;
    } on FormatException {
      throw const SpeechException(
        'The server sent no voice list. Type a voice instead.',
      );
    }
  }

  /// Kokoro-FastAPI serves timed speech at `/dev/captioned_speech`, a sibling
  /// of `/v1/audio/speech`. Any path prefix in front of the speech endpoint
  /// (a reverse proxy at `https://host/kokoro/…`) is kept.
  @visibleForTesting
  static Uri captionedEndpoint(Uri speech) {
    final prefix = speech.path.replaceFirst(
      RegExp(r'(/v1)?/audio/speech/?$'),
      '',
    );
    final base = prefix == speech.path ? '' : prefix;
    return speech.replace(path: '$base/dev/captioned_speech');
  }

  Uri _checkEndpoint(String endpoint) {
    final uri = Uri.tryParse(endpoint.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const SpeechException(
        'Enter an HTTPS speech endpoint without credentials or query parameters.',
      );
    }
    return uri;
  }

  bool _isMp3(Uint8List b) =>
      b.length >= 3 &&
      ((b[0] == 0x49 && b[1] == 0x44 && b[2] == 0x33) ||
          (b[0] == 0xff && (b[1] & 0xe0) == 0xe0));
}
