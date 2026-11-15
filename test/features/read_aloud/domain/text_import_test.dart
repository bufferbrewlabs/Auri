import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:auri/features/read_aloud/data/file_importer.dart';
import 'package:auri/features/read_aloud/domain/text_import.dart';

Uint8List _epub({String title = 'The Book', bool withText = true}) {
  final Archive a = Archive();
  void add(String name, String content) {
    final List<int> bytes = utf8.encode(content);
    a.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  add('mimetype', 'application/epub+zip');
  add(
    'META-INF/container.xml',
    '<?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
        '<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
  );
  add(
    'OEBPS/content.opf',
    '<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/">'
        '<metadata><dc:title>$title</dc:title></metadata>'
        '<manifest><item id="c2" href="text/two.xhtml"/><item id="c1" href="text/one.xhtml"/></manifest>'
        '<spine><itemref idref="c1"/><itemref idref="c2"/></spine></package>',
  );
  add(
    'OEBPS/text/one.xhtml',
    withText
        ? '<html><head><title>x</title><style>p{}</style></head><body><h1>Chapter One</h1><p>It was a <b>dark</b>\n night.</p></body></html>'
        : '<html><body></body></html>',
  );
  add(
    'OEBPS/text/two.xhtml',
    '<html><body><p>Second chapter.</p><script>alert(1)</script></body></html>',
  );
  return Uint8List.fromList(ZipEncoder().encode(a));
}

void main() {
  group('textFromMarkdown', () {
    test('keeps the words a listener should hear', () {
      const String md =
          '# Title\n\n'
          'Some **bold** and _italic_ and `code`.\n\n'
          '- one\n- two\n\n'
          '> quoted\n\n'
          'A [link](https://x.dev) and ![img](a.png).\n\n'
          '```dart\nprint(1);\n```\n\n---\n';
      expect(
        textFromMarkdown(md),
        'Title\n\nSome bold and italic and code.\n\none\ntwo\n\nquoted\n\n'
        'A link and .\n\nprint(1);',
      );
    });
  });

  group('textFromTxt', () {
    test('strips a BOM and tolerates bad UTF-8', () {
      final Uint8List bytes = Uint8List.fromList(<int>[
        0xEF, 0xBB, 0xBF, ...utf8.encode('Hi  there'), 0xFF, //
      ]);
      expect(textFromTxt(bytes), 'Hi there�');
    });
  });

  group('textFromPdfPages', () {
    test('rejoins wrapped lines and hyphenated words, keeps paragraphs', () {
      expect(
        textFromPdfPages(<String>[
          'The quick brown\nfox jum-\nped over.\n\nNew para.',
          'Page two.',
        ]),
        'The quick brown fox jumped over.\n\nNew para.\n\nPage two.',
      );
    });
  });

  group('textFromEpub', () {
    test('reads chapters in spine order with the package title', () {
      final ImportedText book = textFromEpub(_epub());
      expect(book.title, 'The Book');
      expect(
        book.body,
        'Chapter One\n\nIt was a dark night.\n\nSecond chapter.',
      );
    });

    test('a broken file is a readable error', () {
      expect(
        () => textFromEpub(Uint8List.fromList(<int>[1, 2, 3])),
        throwsA(isA<ImportException>()),
      );
    });
  });

  test('titleFromFileName', () {
    expect(titleFromFileName('My_notes-v2.md'), 'My notes v2');
    expect(titleFromFileName('README'), 'README');
  });

  group('FileImporter.read', () {
    const FileImporter importer = FileImporter();

    test('routes by extension and reports the kind', () async {
      final PickedImport md = await importer.read(
        'notes.MD',
        Uint8List.fromList(utf8.encode('## Hi\nthere')),
      );
      expect(md.kind, ImportKind.txt);
      expect(md.text.body, 'Hi\nthere');

      final PickedImport epub = await importer.read('b.epub', _epub());
      expect(epub.kind, ImportKind.epub);
      expect(epub.text.title, 'The Book');
    });

    test('reads .txt files as plain text titled from the name', () async {
      final PickedImport txt = await importer.read(
        'my_story.txt',
        Uint8List.fromList(utf8.encode('Once upon a time.')),
      );
      expect(txt.kind, ImportKind.txt);
      expect(txt.text.title, 'my story');
      expect(txt.text.body, 'Once upon a time.');
    });

    test('a file without an extension gets a helpful message', () async {
      for (final String name in <String>['README', 'notes.']) {
        await expectLater(
          importer.read(name, Uint8List(0)),
          throwsA(
            isA<ImportException>().having(
              (ImportException e) => e.message,
              'message',
              allOf(contains('.txt'), isNot(contains('read . files'))),
            ),
          ),
          reason: name,
        );
      }
    });

    test('unknown extensions are refused with a message', () async {
      await expectLater(
        importer.read('song.mp3', Uint8List(0)),
        throwsA(
          isA<ImportException>().having(
            (ImportException e) => e.message,
            'message',
            contains('.mp3'),
          ),
        ),
      );
    });
  });
}
