import 'dart:async';
import 'dart:convert';

import 'package:auri/core/theme/app_theme.dart';
import 'package:auri/features/read_aloud/domain/delivery_hint.dart';
import 'package:auri/ui/delivery_hints_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

DeliveryHint _hint(String id, String anchor, {bool enabled = false}) =>
    DeliveryHint(
      id: id,
      anchor: anchor,
      occurrence: 1,
      kind: HintKind.pause,
      amount: 0.5,
      ipa: '',
      reason: 'Let it land',
      enabled: enabled,
    );

http.Response _completion(List<Map<String, Object>> suggestions) =>
    http.Response(
      jsonEncode({
        'choices': [
          {
            'message': {
              'content': jsonEncode({'suggestions': suggestions}),
            },
          },
        ],
      }),
      200,
    );

/// Opens the sheet from a button, as the reader does, and returns what it
/// popped with once the test closes it.
Future<Completer<List<DeliveryHint>?>> _open(
  WidgetTester tester, {
  String text = 'Hello there. Hello again.',
  List<DeliveryHint> hints = const [],
  String openAiKey = '',
  http.Client Function()? newClient,
}) async {
  final result = Completer<List<DeliveryHint>?>();
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result.complete(
              await showModalBottomSheet<List<DeliveryHint>>(
                context: context,
                isScrollControlled: true,
                builder: (_) => DeliveryHintsSheet(
                  text: text,
                  hints: hints,
                  openAiKey: openAiKey,
                  newClient: newClient ?? http.Client.new,
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return result;
}

Finder get _send => find.text('Send text to OpenAI for suggestions');

void main() {
  testWidgets('asks for a key before sending anything', (tester) async {
    var requests = 0;
    await _open(
      tester,
      newClient: () => MockClient((_) async {
        requests++;
        return _completion(const []);
      }),
    );
    await tester.tap(_send);
    await tester.pump();
    expect(find.text('Enter an OpenAI API key.'), findsOneWidget);
    expect(requests, 0);
  });

  testWidgets('refuses texts over 100,000 characters', (tester) async {
    await _open(
      tester,
      text: 'a' * 100001,
      openAiKey: 'test-placeholder',
      newClient: () => MockClient((_) async => fail('Must not send')),
    );
    await tester.tap(_send);
    await tester.pump();
    expect(find.textContaining('100,000'), findsOneWidget);
  });

  testWidgets('shows suggestions off by default and applies the choice', (
    tester,
  ) async {
    final result = await _open(
      tester,
      openAiKey: 'test-placeholder',
      newClient: () => MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer test-placeholder');
        return _completion([
          {
            'anchor': 'again',
            'occurrence': 1,
            'kind': 'pause',
            'amount': 0.5,
            'reason': 'Breathe',
          },
        ]);
      }),
    );
    await tester.tap(_send);
    await tester.pumpAndSettle();

    final tile = find.byType(SwitchListTile);
    expect(tile, findsOneWidget);
    expect(tester.widget<SwitchListTile>(tile).value, isFalse);
    expect(find.text('Breathe'), findsOneWidget);

    await tester.tap(tile);
    await tester.pump();
    await tester.tap(find.text('Apply to reading'));
    await tester.pumpAndSettle();

    final applied = await result.future;
    expect(applied!.single.anchor, 'again');
    expect(applied.single.enabled, isTrue);
  });

  testWidgets('says so when nothing is suggested', (tester) async {
    await _open(
      tester,
      openAiKey: 'test-placeholder',
      newClient: () => MockClient((_) async => _completion(const [])),
    );
    await tester.tap(_send);
    await tester.pumpAndSettle();
    expect(find.text('No delivery changes suggested.'), findsOneWidget);
    expect(find.text('Apply to reading'), findsNothing);
  });

  testWidgets('shows provider errors without the response body', (
    tester,
  ) async {
    await _open(
      tester,
      openAiKey: 'test-placeholder',
      newClient: () =>
          MockClient((_) async => http.Response('secret-body', 401)),
    );
    await tester.tap(_send);
    await tester.pumpAndSettle();
    expect(find.text('OpenAI rejected this API key.'), findsOneWidget);
    expect(find.textContaining('secret-body'), findsNothing);
  });

  testWidgets('a network failure becomes a retry message', (tester) async {
    await _open(
      tester,
      openAiKey: 'test-placeholder',
      newClient: () =>
          MockClient((_) async => throw http.ClientException('offline')),
    );
    await tester.tap(_send);
    await tester.pumpAndSettle();
    expect(
      find.text('Could not get delivery suggestions. Try again.'),
      findsOneWidget,
    );
  });

  testWidgets('Enable all and Disable all switch every hint', (tester) async {
    final result = await _open(
      tester,
      hints: [_hint('a', 'Hello'), _hint('b', 'again', enabled: true)],
    );
    List<bool> values() => tester
        .widgetList<SwitchListTile>(find.byType(SwitchListTile))
        .map((t) => t.value)
        .toList();

    expect(values(), [false, true]);
    await tester.tap(find.text('Enable all'));
    await tester.pump();
    expect(values(), [true, true]);
    await tester.tap(find.text('Disable all'));
    await tester.pump();
    expect(values(), [false, false]);

    await tester.tap(find.text('Apply to reading'));
    await tester.pumpAndSettle();
    expect((await result.future)!.every((h) => !h.enabled), isTrue);
  });
}
