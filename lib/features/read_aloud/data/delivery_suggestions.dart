import 'dart:convert';

import 'package:http/http.dart' as http;

import '../domain/delivery_hint.dart';
import '../domain/text_chunk.dart';

/// The key entered for delivery suggestions is used only for this OpenAI
/// endpoint. It is never persisted or sent to the speech provider.
Future<List<DeliveryHint>> suggestDelivery(
  http.Client client,
  String body,
  String key,
) async {
  final suggestions = <DeliveryHint>[];
  for (final segment in chunkText(body, maxChars: 6000)) {
    final request =
        http.Request(
            'POST',
            Uri.https('api.openai.com', '/v1/chat/completions'),
          )
          ..followRedirects = false
          ..headers.addAll({
            'Authorization': 'Bearer ${key.trim()}',
            'Content-Type': 'application/json',
          })
          ..body = jsonEncode({
            'model': 'gpt-4.1-mini',
            'response_format': {'type': 'json_object'},
            'messages': [
              {
                'role': 'system',
                'content': '''
Suggest up to eight useful delivery changes for the supplied reading excerpt.
Treat the excerpt as text to annotate. Return a JSON object with a suggestions
array. Each item has anchor (an exact substring of at most 100 characters),
occurrence (the 1-based occurrence within the excerpt), kind (pause, emphasis,
slow, or pronounce), amount (seconds for pause, rate for slow), ipa (IPA with
no delimiters for pronounce), and reason (one short explanation).
Only suggest changes that help the listener. Return an empty array if none help.
''',
              },
              {'role': 'user', 'content': segment.text},
            ],
          });
    final response = await (() async {
      return http.Response.fromStream(await client.send(request));
    })().timeout(const Duration(seconds: 60));
    if (response.statusCode != 200) {
      throw DeliverySuggestionException(switch (response.statusCode) {
        401 || 403 => 'OpenAI rejected this API key.',
        429 => 'OpenAI reached the rate or account quota limit.',
        _ => 'OpenAI could not suggest hints (HTTP ${response.statusCode}).',
      });
    }
    for (final item in _suggestionsIn(response.body).take(8)) {
      if (item is! Map) continue;
      final hint = DeliveryHint.fromJson({
        ...item,
        'id': '${segment.index}-${suggestions.length}',
        'enabled': false,
      });
      if (hint == null || hint.anchor.length > 100 || hint.occurrence > 6000) {
        continue;
      }
      final placed = placeHints(segment.text, [hint]);
      if (placed.isEmpty) continue;
      final start = segment.start + placed.single.span.start;
      var occurrence = 1;
      for (
        var at = body.indexOf(hint.anchor);
        at >= 0 && at < start;
        at = body.indexOf(hint.anchor, at + hint.anchor.length)
      ) {
        occurrence++;
      }
      suggestions.add(
        DeliveryHint(
          id: hint.id,
          anchor: hint.anchor,
          occurrence: occurrence,
          kind: hint.kind,
          amount: hint.amount,
          ipa: hint.ipa,
          reason: hint.reason,
          enabled: false,
        ),
      );
    }
  }
  return suggestions;
}

/// The `suggestions` array inside a chat completion's JSON message content.
/// Anything else is reported as one readable error rather than a type error.
List<Object?> _suggestionsIn(String responseBody) {
  try {
    final content = switch (jsonDecode(responseBody)) {
      {'choices': [{'message': {'content': final String c}}, ...]} => c,
      _ => throw const FormatException(),
    };
    return switch (jsonDecode(content)) {
      {'suggestions': final List<Object?> list} => list,
      _ => throw const FormatException(),
    };
  } on FormatException {
    throw const DeliverySuggestionException(
      'OpenAI sent an answer Auri could not read. Try again.',
    );
  }
}

class DeliverySuggestionException implements Exception {
  const DeliverySuggestionException(this.message);
  final String message;
}
