import 'dart:convert';

import 'package:auri/features/read_aloud/data/delivery_suggestions.dart';
import 'package:auri/features/read_aloud/domain/delivery_hint.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'requests suggestions, places the right occurrence and requires opt-in',
    () async {
      final client = MockClient((request) async {
        expect(
          request.url,
          Uri.https('api.openai.com', '/v1/chat/completions'),
        );
        expect(request.headers['Authorization'], 'Bearer test-placeholder');
        expect(request.followRedirects, isFalse);
        final body = jsonDecode(request.body) as Map<String, Object?>;
        final messages = body['messages']! as List<Object?>;
        expect((messages.last! as Map)['content'], 'Hello. Hello.');
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content': jsonEncode({
                    'suggestions': [
                      {
                        'anchor': 'Hello',
                        'occurrence': 2,
                        'kind': 'pause',
                        'amount': 0.5,
                      },
                      {
                        'anchor': 'Absent',
                        'occurrence': 1,
                        'kind': 'slow',
                        'amount': 0.8,
                      },
                    ],
                  }),
                },
              },
            ],
          }),
          200,
        );
      });
      addTearDown(client.close);
      final hints = await suggestDelivery(
        client,
        'Hello. Hello.',
        'test-placeholder',
      );
      expect(hints.single.enabled, isFalse);
      expect(hints.single.kind, HintKind.pause);
      expect(placeHints('Hello. Hello.', hints).single.span.start, 7);
    },
  );

  group('fails with a readable message', () {
    Future<void> expectMessage(http.Response response, Matcher message) async {
      final client = MockClient((_) async => response);
      addTearDown(client.close);
      await expectLater(
        suggestDelivery(client, 'Hello.', 'test-placeholder'),
        throwsA(
          isA<DeliverySuggestionException>().having(
            (e) => e.message,
            'message',
            message,
          ),
        ),
      );
    }

    String completion(Object? content) => jsonEncode({
      'choices': [
        {
          'message': {'content': content},
        },
      ],
    });

    test('for rejected keys, quotas and server errors', () async {
      await expectMessage(http.Response('', 401), contains('API key'));
      await expectMessage(http.Response('', 403), contains('API key'));
      await expectMessage(http.Response('', 429), contains('quota'));
      await expectMessage(http.Response('secret body', 500), contains('500'));
      await expectMessage(
        http.Response('secret body', 500),
        isNot(contains('secret')),
      );
    });

    test('for responses of the wrong shape', () async {
      for (final body in [
        'not json',
        jsonEncode({'choices': <Object>[]}),
        jsonEncode({
          'choices': [
            {'message': <String, Object>{}},
          ],
        }),
        completion(42),
        completion('not json either'),
        completion(jsonEncode({'suggestions': 'nope'})),
        completion(jsonEncode(['no', 'object'])),
      ]) {
        await expectMessage(http.Response(body, 200), contains('could not'));
      }
    });
  });

  test('ignores malformed items and caps each segment at 8', () async {
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {
                'content': jsonEncode({
                  'suggestions': [
                    'not a map',
                    {'anchor': 'Hello', 'occurrence': 1, 'kind': 'bogus'},
                    for (var i = 0; i < 12; i++)
                      {'anchor': 'Hello', 'occurrence': 1, 'kind': 'pause'},
                  ],
                }),
              },
            },
          ],
        }),
        200,
      ),
    );
    addTearDown(client.close);
    final hints = await suggestDelivery(client, 'Hello.', 'test-placeholder');
    expect(hints.length, 6);
    expect(hints.every((h) => !h.enabled), isTrue);
  });
}
