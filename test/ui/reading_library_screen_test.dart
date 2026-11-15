import 'package:auri/core/theme/app_theme.dart';
import 'package:auri/features/read_aloud/data/reading_library.dart';
import 'package:auri/ui/reading_library_screen.dart';
import 'package:auri/voice_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Harness {
  _Harness(this.library);
  final ReadingLibrary library;
  final deleted = <String>[];
  final renamed = <SavedReading>[];
  SavedReading? opened;
}

Future<_Harness> _pump(WidgetTester tester, ReadingLibrary library) async {
  final h = _Harness(library);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            h.opened = await Navigator.push<SavedReading>(
              context,
              MaterialPageRoute(
                builder: (_) => ReadingLibraryScreen(
                  library: library,
                  onDelete: h.deleted.add,
                  onRename: h.renamed.add,
                ),
              ),
            );
          },
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return h;
}

Future<void> _menu(WidgetTester tester, String title, String action) async {
  await tester.tap(
    find.descendant(
      of: find.widgetWithText(ListTile, title),
      matching: find.byTooltip('Reading actions'),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text(action).last);
  await tester.pumpAndSettle();
}

void main() {
  // Made inside each test body: a library created in setUp would complete its
  // futures outside the widget tester's fake-async zone and never settle.
  ReadingLibrary newLibrary() => ReadingLibrary(MemorySettingsStore());

  testWidgets('an empty library says how to save a reading', (tester) async {
    final library = newLibrary();
    await _pump(tester, library);
    expect(find.text('Save a reading from the player menu.'), findsOneWidget);
  });

  testWidgets('lists readings with their start or resume progress', (
    tester,
  ) async {
    final library = newLibrary();
    await library.save(
      const SavedReading(
        id: 'a',
        title: 'Fresh',
        text: 'Start here',
        offset: 0,
      ),
    );
    await library.save(
      const SavedReading(id: 'b', title: '', text: '0123456789', offset: 5),
    );
    await _pump(tester, library);
    expect(find.text('Start here'), findsOneWidget);
    expect(find.text('Untitled'), findsOneWidget);
    expect(find.text('Resume · 50%'), findsOneWidget);
  });

  testWidgets('tapping a reading returns it to the reader', (tester) async {
    final library = newLibrary();
    await library.save(
      const SavedReading(id: 'a', title: 'Pick me', text: 'x', offset: 0),
    );
    final h = await _pump(tester, library);
    await tester.tap(find.text('Pick me'));
    await tester.pumpAndSettle();
    expect(h.opened?.id, 'a');
  });

  testWidgets('rename saves the trimmed title and reports it', (tester) async {
    final library = newLibrary();
    await library.save(
      const SavedReading(id: 'a', title: 'Old', text: 'x', offset: 0),
    );
    final h = await _pump(tester, library);
    await _menu(tester, 'Old', 'Rename');
    await tester.enterText(find.byType(TextFormField), '  New name  ');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('New name'), findsOneWidget);
    expect(h.renamed.single.title, 'New name');
    expect((await library.list()).single.title, 'New name');
  });

  testWidgets('delete asks first; Cancel keeps the reading', (tester) async {
    final library = newLibrary();
    await library.save(
      const SavedReading(id: 'a', title: 'Keep?', text: 'x', offset: 0),
    );
    final h = await _pump(tester, library);

    await _menu(tester, 'Keep?', 'Delete');
    expect(find.text('Delete reading?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(h.deleted, isEmpty);
    expect(await library.list(), hasLength(1));

    await _menu(tester, 'Keep?', 'Delete');
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(h.deleted, ['a']);
    expect(await library.list(), isEmpty);
    expect(find.text('Save a reading from the player menu.'), findsOneWidget);
  });

  testWidgets('a failed write shows a message and keeps the list', (
    tester,
  ) async {
    final failing = _ReadOnlyStore();
    final lib = ReadingLibrary(failing);
    failing.allowWrites = true;
    await lib.save(
      const SavedReading(id: 'a', title: 'Stuck', text: 'x', offset: 0),
    );
    failing.allowWrites = false;
    final h = await _pump(tester, lib);

    await _menu(tester, 'Stuck', 'Delete');
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(find.text('The reading could not be updated.'), findsOneWidget);
    expect(find.text('Stuck'), findsOneWidget);
    expect(h.deleted, isEmpty);
  });
}

class _ReadOnlyStore extends MemorySettingsStore {
  var allowWrites = false;

  @override
  Future<void> write(String key, String? value) async {
    if (!allowWrites) throw StateError('read-only');
    await super.write(key, value);
  }
}
