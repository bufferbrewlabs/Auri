import 'dart:convert';

import '../../../voice_settings.dart';
import '../domain/delivery_hint.dart';

class SavedReading {
  const SavedReading({
    required this.id,
    required this.title,
    required this.text,
    required this.offset,
    this.hints = const [],
  });

  final String id;
  final String title;
  final String text;
  final int offset;
  final List<DeliveryHint> hints;

  String get displayTitle => title.trim().isEmpty ? 'Untitled' : title;

  SavedReading rename(String title) => SavedReading(
    id: id,
    title: title,
    text: text,
    offset: offset,
    hints: hints,
  );

  static SavedReading? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    final title = value['title'];
    final text = value['text'];
    final offset = value['offset'];
    if (id is! String ||
        title is! String ||
        text is! String ||
        offset is! int) {
      return null;
    }
    List<DeliveryHint> readHints(Object? items) => [
      for (final item in items is List ? items : const [])
        ?DeliveryHint.fromJson(item),
    ];
    return SavedReading(
      id: id,
      title: title,
      text: text,
      offset: offset.clamp(0, text.length),
      hints: readHints(value['hints']),
    );
  }

  Map<String, Object> toJson() => {
    'id': id,
    'title': title,
    'text': text,
    'offset': offset,
    'hints': hints.map((hint) => hint.toJson()).toList(),
  };
}

/// Explicitly saved readings stay in this installation's storage.
class ReadingLibrary {
  ReadingLibrary(this.store);

  final SettingsStore store;
  static const _key = 'read_aloud.library';
  Future<void> _pending = Future.value();

  Future<List<SavedReading>> _load() async {
    final raw = await store.read(_key);
    if (raw == null) return [];
    final Object? data;
    try {
      data = jsonDecode(raw);
    } on FormatException {
      // Unreadable storage must not lock the reader out of the library; the
      // next save starts a fresh list.
      return [];
    }
    return [
      for (final value in data is List ? data : const [])
        ?SavedReading.fromJson(value),
    ];
  }

  Future<List<SavedReading>> list() async {
    await _pending;
    return _load();
  }

  Future<void> _change(void Function(List<SavedReading>) change) {
    final write = _pending.then((_) async {
      final readings = await _load();
      change(readings);
      await store.write(
        _key,
        jsonEncode(readings.map((r) => r.toJson()).toList()),
      );
    });
    _pending = write.catchError((Object _) {});
    return write;
  }

  Future<void> save(SavedReading reading) => _change((readings) {
    readings.removeWhere((r) => r.id == reading.id);
    readings.insert(0, reading);
  });

  Future<void> delete(String id) =>
      _change((readings) => readings.removeWhere((r) => r.id == id));
}
