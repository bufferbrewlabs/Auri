import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:pdfrx/pdfrx.dart';

import '../domain/text_import.dart';

/// Where an imported reading came from — the `source_kind` column.
enum ImportKind { txt, pdf, epub }

typedef PickedImport = ({ImportedText text, ImportKind kind});

/// Lets the reader pick a TXT, Markdown, PDF or EPUB file and turns it into
/// text. Null when the picker was cancelled.
///
/// Everything runs on the device: the file is never uploaded, only the text
/// the reader then chooses to save.
class FileImporter {
  const FileImporter();

  static const List<String> extensions = <String>[
    'txt',
    'md',
    'markdown',
    'pdf',
    'epub',
  ];

  Future<PickedImport?> pick() async {
    final List<PlatformFile> files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: extensions,
    );
    if (files.isEmpty) return null;
    final PlatformFile file = files.first;
    return read(file.name, await file.readAsBytes());
  }

  /// Text from a file's [name] and [bytes], by extension.
  Future<PickedImport> read(String name, Uint8List bytes) async {
    final String ext = name.contains('.')
        ? name.substring(name.lastIndexOf('.') + 1).toLowerCase()
        : '';
    final String title = titleFromFileName(name);
    switch (ext) {
      case 'txt':
        return (
          text: (title: title, body: textFromTxt(bytes)),
          kind: ImportKind.txt,
        );
      case 'md':
      case 'markdown':
        return (
          text: (
            title: title,
            body: textFromMarkdown(utf8.decode(bytes, allowMalformed: true)),
          ),
          kind: ImportKind.txt,
        );
      case 'epub':
        return (
          text: textFromEpub(bytes, fallbackTitle: title),
          kind: ImportKind.epub,
        );
      case 'pdf':
        return (
          text: (title: title, body: await _pdfText(bytes)),
          kind: ImportKind.pdf,
        );
      case '':
        throw const ImportException(
          'Auri cannot tell what kind of file this is. '
          'Use a .txt, .md, .pdf or .epub file.',
        );
      default:
        throw ImportException('Auri cannot read .$ext files yet.');
    }
  }

  Future<String> _pdfText(Uint8List bytes) async {
    final PdfDocument doc;
    try {
      doc = await PdfDocument.openData(bytes);
    } catch (_) {
      throw const ImportException(
        'This PDF could not be opened. It may be password-protected.',
      );
    }
    try {
      final List<String> pages = <String>[];
      for (final PdfPage page in doc.pages) {
        pages.add((await page.loadText())?.fullText ?? '');
      }
      final String text = textFromPdfPages(pages);
      if (text.isEmpty) {
        throw const ImportException(
          'This PDF has no text layer — it is probably scanned images.',
        );
      }
      return text;
    } finally {
      await doc.dispose();
    }
  }
}
