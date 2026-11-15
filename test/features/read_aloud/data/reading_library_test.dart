import 'dart:convert';

import 'package:auri/features/read_aloud/data/reading_library.dart';
import 'package:auri/features/read_aloud/domain/delivery_hint.dart';
import 'package:auri/voice_settings.dart';
import 'package:flutter_test/flutter_test.dart';

const _key = 'read_aloud.library';

SavedReading _reading(String id, {String title = 'T', int offset = 0}) =>
    SavedReading(id: id, title: title, text: 'Hello world.', offset: offset);

void main() {
  late MemorySettingsStore store;
  late ReadingLibrary library;

  setUp(() {
    store = MemorySettingsStore();
    library = ReadingLibrary(store);
  });

  test('is empty before anything is saved', () async {
    expect(await library.list(), isEmpty);
  });

  test('save puts the newest first and replaces by id', () async {
    await library.save(_reading('a'));
    await library.save(_reading('b'));
    await library.save(_reading('a', title: 'A again', offset: 5));
    final readings = await library.list();
    expect(readings.map((r) => r.id), ['a', 'b']);
    expect(readings.first.title, 'A again');
    expect(readings.first.offset, 5);
  });

  test('delete removes only that reading', () async {
    await library.save(_reading('a'));
    await library.save(_reading('b'));
    await library.delete('a');
    expect((await library.list()).map((r) => r.id), ['b']);
  });

  test('concurrent changes are applied in order, none lost', () async {
    await Future.wait([
      for (var i = 0; i < 10; i++) library.save(_reading('r$i')),
    ]);
    expect((await library.list()).length, 10);
  });

  test('a failed write does not block later changes', () async {
    final failing = _FailingOnceStore();
    final lib = ReadingLibrary(failing);
    await expectLater(lib.save(_reading('a')), throwsA(isA<StateError>()));
    await lib.save(_reading('b'));
    expect((await lib.list()).map((r) => r.id), ['b']);
  });

  test('corrupt storage reads as empty and the next save recovers', () async {
    store.values[_key] = '{not json';
    expect(await library.list(), isEmpty);
    await library.save(_reading('a'));
    expect((await library.list()).single.id, 'a');
  });

  test('skips malformed entries but keeps the valid ones', () async {
    store.values[_key] = jsonEncode([
      _reading('ok').toJson(),
      {'id': 'missing fields'},
      'garbage',
      {'id': 1, 'title': 'x', 'text': 'y', 'offset': 0},
    ]);
    expect((await library.list()).single.id, 'ok');
  });

  test('a non-list document reads as empty', () async {
    store.values[_key] = jsonEncode({'id': 'a'});
    expect(await library.list(), isEmpty);
  });

  group('SavedReading', () {
    test('round-trips through JSON with its hints', () {
      const hint = DeliveryHint(
        id: 'h1',
        anchor: 'world',
        occurrence: 1,
        kind: HintKind.pause,
        amount: 0.5,
        ipa: '',
        reason: 'breath',
        enabled: true,
      );
      const reading = SavedReading(
        id: 'a',
        title: 'Title',
        text: 'Hello world.',
        offset: 6,
        hints: [hint],
      );
      final back = SavedReading.fromJson(
        jsonDecode(jsonEncode(reading.toJson())),
      )!;
      expect(back.id, 'a');
      expect(back.title, 'Title');
      expect(back.text, 'Hello world.');
      expect(back.offset, 6);
      expect(back.hints.single.anchor, 'world');
      expect(back.hints.single.kind, HintKind.pause);
      expect(back.hints.single.enabled, isTrue);
    });

    test('clamps an offset outside the text', () {
      for (final (raw, expected) in [(-4, 0), (999, 12)]) {
        final r = SavedReading.fromJson({
          'id': 'a',
          'title': '',
          'text': 'Hello world.',
          'offset': raw,
        });
        expect(r!.offset, expected);
      }
    });

    test('drops malformed hints', () {
      final r = SavedReading.fromJson({
        'id': 'a',
        'title': '',
        'text': 'x',
        'offset': 0,
        'hints': [
          {'kind': 'nonsense'},
          42,
        ],
      });
      expect(r!.hints, isEmpty);
    });

    test('rename keeps everything else; blank titles display as Untitled', () {
      final r = _reading('a', title: 'Old', offset: 3).rename('  ');
      expect(r.id, 'a');
      expect(r.offset, 3);
      expect(r.text, 'Hello world.');
      expect(r.displayTitle, 'Untitled');
      expect(_reading('b', title: 'Named').displayTitle, 'Named');
    });
  });
}

class _FailingOnceStore extends MemorySettingsStore {
  var _failed = false;

  @override
  Future<void> write(String key, String? value) async {
    if (!_failed) {
      _failed = true;
      throw StateError('disk full');
    }
    await super.write(key, value);
  }
}
