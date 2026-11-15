import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:auri/speech_api.dart';
import 'package:auri/mp3.dart';

void main() {
  Future<Uint8List> generate(
    SpeechApi api, {
    String text = 'Hello.',
    String endpoint = 'https://example.com/v1/audio/speech',
  }) => api.generate(
    text: text,
    endpoint: endpoint,
    apiKey: 'test-placeholder',
    model: 'tts-1',
    voice: 'alloy',
  );
  test('chunks long text, authenticates and requests MP3', () async {
    var count = 0;
    final api = SpeechApi(
      MockClient((request) async {
        count++;
        expect(request.headers['Authorization'], 'Bearer test-placeholder');
        final body = jsonDecode(request.body) as Map;
        expect(body['response_format'], 'mp3');
        expect((body['input'] as String).length, lessThanOrEqualTo(1200));
        expect(request.followRedirects, false);
        return http.Response.bytes([0xff, 0xfb, 0x90, 0], 200);
      }),
    );
    final audio = await generate(
      api,
      text: List.filled(600, 'Hello.').join(' '),
    );
    expect(count, greaterThan(1));
    expect(audio.length, count * 4);
  });
  test('Kokoro requests timed audio and allows delivery tags', () async {
    final api = SpeechApi(
      MockClient((request) async {
        expect(request.url.path, '/dev/captioned_speech');
        expect(request.headers['Authorization'], 'Bearer test-placeholder');
        expect(request.followRedirects, false);
        final body = jsonDecode(request.body) as Map;
        expect(body['return_timestamps'], true);
        expect(body['allow_voice_tags'], true);
        expect(body['input'], 'Hello [pause:0.5s]');
        return http.Response(
          jsonEncode({
            'audio': base64Encode([0xff, 0xfb, 0x90, 0]),
            'timestamps': [
              {'word': 'Hello', 'start_time': 0.1, 'end_time': 0.4},
              {'word': 'bad', 'start_time': -5, 'end_time': -1},
            ],
          }),
          200,
        );
      }),
    );
    final result = await api.captioned(
      endpoint: 'https://example.com/v1/audio/speech',
      apiKey: 'test-placeholder',
      voice: 'af_heart',
      text: 'Hello [pause:0.5s]',
      useMarkup: true,
    );
    expect(result.audio.length, 4);
    expect(result.timings.single.word, 'Hello');
    expect(result.timings.single.start, const Duration(milliseconds: 100));
  });

  test('Kokoro falls back to standard speech only for unmarked text', () async {
    final requests = <String>[];
    final api = SpeechApi(
      MockClient((request) async {
        requests.add(request.url.path);
        return request.url.path == '/dev/captioned_speech'
            ? http.Response('', 404)
            : http.Response.bytes([0xff, 0xfb, 0x90, 0], 200);
      }),
    );
    Future<void> speak(bool useMarkup) => api.captioned(
      endpoint: 'https://example.com/v1/audio/speech',
      apiKey: 'test-placeholder',
      voice: 'af_heart',
      text: 'Hello',
      useMarkup: useMarkup,
    );
    await speak(false);
    await expectLater(speak(true), throwsA(isA<SpeechException>()));
    expect(requests, [
      '/dev/captioned_speech',
      '/v1/audio/speech',
      '/dev/captioned_speech',
    ]);
  });

  group('captioned endpoint', () {
    String path(String url) =>
        SpeechApi.captionedEndpoint(Uri.parse(url)).toString();

    test('sits next to /v1/audio/speech at the host root', () {
      expect(
        path('https://example.com/v1/audio/speech'),
        'https://example.com/dev/captioned_speech',
      );
    });

    test('keeps a reverse-proxy path prefix', () {
      expect(
        path('https://example.com/kokoro/v1/audio/speech'),
        'https://example.com/kokoro/dev/captioned_speech',
      );
      expect(
        path('https://example.com:8443/tts/audio/speech'),
        'https://example.com:8443/tts/dev/captioned_speech',
      );
    });

    test('falls back to the root for other speech paths', () {
      expect(
        path('https://example.com/custom/speak'),
        'https://example.com/dev/captioned_speech',
      );
    });

    test('is the URL captioned() posts to', () async {
      Uri? sent;
      final api = SpeechApi(
        MockClient((request) async {
          sent = request.url;
          return http.Response(
            jsonEncode({
              'audio': base64Encode([0xff, 0xfb, 0x90, 0]),
            }),
            200,
          );
        }),
      );
      await api.captioned(
        endpoint: 'https://example.com/kokoro/v1/audio/speech',
        apiKey: 'test-placeholder',
        voice: 'af_heart',
        text: 'Hello',
        useMarkup: false,
      );
      expect(sent?.path, '/kokoro/dev/captioned_speech');
    });
  });

  test(
    'Kokoro reports malformed captioned bodies as SpeechException',
    () async {
      for (final body in [
        'not json',
        jsonEncode([1, 2]),
        jsonEncode({'audio': 42}),
        jsonEncode({'audio': '%%% not base64 %%%'}),
        jsonEncode({
          'audio': base64Encode(utf8.encode('<html>not audio</html>')),
        }),
      ]) {
        final api = SpeechApi(
          MockClient((_) async => http.Response(body, 200)),
        );
        await expectLater(
          api.captioned(
            endpoint: 'https://example.com/v1/audio/speech',
            apiKey: 'test-placeholder',
            voice: 'af_heart',
            text: 'Hello',
            useMarkup: true,
          ),
          throwsA(isA<SpeechException>()),
          reason: body,
        );
      }
    },
  );

  test('Kokoro drops malformed timestamps and sorts the rest', () async {
    final api = SpeechApi(
      MockClient(
        (_) async => http.Response(
          jsonEncode({
            'audio': base64Encode([0x49, 0x44, 0x33, 4]),
            'timestamps': [
              {'word': 'world', 'start_time': 0.5, 'end_time': 0.9},
              'garbage',
              {'word': 'Hello', 'start_time': 0.1, 'end_time': 0.4},
            ],
          }),
          200,
        ),
      ),
    );
    final result = await api.captioned(
      endpoint: 'https://example.com/v1/audio/speech',
      apiKey: 'test-placeholder',
      voice: 'af_heart',
      text: 'Hello world',
      useMarkup: true,
    );
    expect(result.timings.map((t) => t.word), ['Hello', 'world']);
  });

  group('voices', () {
    test('lists bare and object ids, sorted, from /audio/voices', () async {
      final api = SpeechApi(
        MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.path, '/v1/audio/voices');
          expect(request.headers['Authorization'], 'Bearer test-placeholder');
          return http.Response(
            jsonEncode({
              'voices': [
                'bf_emma',
                {'id': 'af_heart'},
                {'name': 'no id'},
                7,
              ],
            }),
            200,
          );
        }),
      );
      expect(
        await api.voices(
          endpoint: 'https://example.com/v1/audio/speech',
          apiKey: 'test-placeholder',
        ),
        ['af_heart', 'bf_emma'],
      );
    });

    Future<void> voicesFail(
      http.Response response, {
      String endpoint = 'https://example.com/v1/audio/speech',
      String key = 'test-placeholder',
      int? status,
    }) => expectLater(
      SpeechApi(
        MockClient((_) async => response),
      ).voices(endpoint: endpoint, apiKey: key),
      throwsA(isA<SpeechException>().having((e) => e.status, 'status', status)),
    );

    test('reports a rejected key with its status', () async {
      await voicesFail(http.Response('', 401), status: 401);
      await voicesFail(http.Response('', 403), status: 403);
    });

    test('fails cleanly on errors, empty lists and non-JSON', () async {
      await voicesFail(http.Response('', 500));
      await voicesFail(http.Response(jsonEncode({'voices': <String>[]}), 200));
      await voicesFail(http.Response('<html>', 200));
    });

    test('needs a key and an /audio/speech endpoint', () async {
      await voicesFail(http.Response('', 200), key: '  ');
      await voicesFail(
        http.Response('', 200),
        endpoint: 'https://example.com/speak',
      );
    });
  });

  test('generate validates its inputs before any request', () async {
    final api = SpeechApi(MockClient((_) async => fail('Must not send')));
    await expectLater(
      generate(api, text: '   '),
      throwsA(isA<SpeechException>()),
    );
    await expectLater(
      api.generate(
        text: 'Hello.',
        endpoint: 'https://example.com/v1/audio/speech',
        apiKey: ' ',
        model: 'tts-1',
        voice: 'alloy',
      ),
      throwsA(isA<SpeechException>()),
    );
  });

  test('maps rate limits to a quota message', () async {
    final api = SpeechApi(MockClient((_) async => http.Response('', 429)));
    await expectLater(
      generate(api),
      throwsA(
        isA<SpeechException>()
            .having((e) => e.status, 'status', 429)
            .having((e) => e.message, 'message', contains('quota')),
      ),
    );
  });

  test('rejects insecure endpoints before sending a key', () async {
    final api = SpeechApi(
      MockClient((_) async {
        fail('Must not send credentials');
      }),
    );
    for (final url in [
      'http://example.com',
      'https://user:pass@example.com',
      'https://example.com?key=value',
    ]) {
      await expectLater(
        generate(api, endpoint: url),
        throwsA(isA<SpeechException>()),
      );
    }
  });
  test('does not expose provider response bodies in errors', () async {
    final api = SpeechApi(
      MockClient(
        (_) async => http.Response('sensitive-provider-response', 401),
      ),
    );
    await expectLater(
      generate(api),
      throwsA(
        isA<SpeechException>().having(
          (e) => e.message,
          'message',
          isNot(contains('sensitive')),
        ),
      ),
    );
  });
  test('rejects non-audio success and redirected responses', () async {
    for (final status in [200, 302]) {
      final api = SpeechApi(
        MockClient((_) async => http.Response('{}', status)),
      );
      await expectLater(generate(api), throwsA(isA<SpeechException>()));
    }
  });
  test(
    'MP3 concatenation strips later ID3 metadata and sanitizes filenames',
    () {
      final part = Uint8List.fromList([
        0x49,
        0x44,
        0x33,
        4,
        0,
        0,
        0,
        0,
        0,
        0,
        0xff,
        0xfb,
        0x90,
        0,
      ]);
      expect(concatMp3([part, part]).length, 18);
      expect(mp3FileName('A/B: C?'), 'A B C.mp3');
    },
  );
}
