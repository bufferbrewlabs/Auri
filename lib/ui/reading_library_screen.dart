import 'package:flutter/material.dart';

import '../features/read_aloud/data/reading_library.dart';

class ReadingLibraryScreen extends StatefulWidget {
  const ReadingLibraryScreen({
    super.key,
    required this.library,
    required this.onDelete,
    required this.onRename,
  });

  final ReadingLibrary library;
  final ValueChanged<String> onDelete;
  final ValueChanged<SavedReading> onRename;

  @override
  State<ReadingLibraryScreen> createState() => _ReadingLibraryScreenState();
}

class _ReadingLibraryScreenState extends State<ReadingLibraryScreen> {
  late Future<List<SavedReading>> _readings = widget.library.list();

  Future<void> _rename(SavedReading reading) async {
    var title = reading.title;
    final name = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Rename reading'),
        content: TextFormField(
          initialValue: title,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Title'),
          onChanged: (value) => title = value,
          onFieldSubmitted: (value) => Navigator.pop(dialog, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, title.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name != null && mounted) {
      final renamed = reading.rename(name);
      await _change(() async {
        await widget.library.save(renamed);
        widget.onRename(renamed);
      });
    }
  }

  Future<void> _delete(SavedReading reading) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Delete reading?'),
        content: Text(reading.displayTitle),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _change(() async {
        await widget.library.delete(reading.id);
        widget.onDelete(reading.id);
      });
    }
  }

  Future<void> _change(Future<void> Function() update) async {
    try {
      await update();
      // A block body: an arrow would return the Future from setState, which
      // Flutter rejects (debug builds then showed the error snackbar below).
      if (mounted) {
        setState(() {
          _readings = widget.library.list();
        });
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('The reading could not be updated.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Saved readings')),
    body: FutureBuilder<List<SavedReading>>(
      future: _readings,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Center(child: Text('Could not open saved readings.'));
        }
        final readings = snapshot.data;
        if (readings == null) {
          return const Center(child: CircularProgressIndicator());
        }
        if (readings.isEmpty) {
          return const Center(
            child: Text('Save a reading from the player menu.'),
          );
        }
        return ListView.builder(
          itemCount: readings.length,
          itemBuilder: (context, i) {
            final reading = readings[i];
            final progress = reading.text.isEmpty
                ? 0
                : (100 * reading.offset / reading.text.length).round();
            return ListTile(
              leading: const Icon(Icons.article_outlined),
              title: Text(reading.displayTitle),
              subtitle: Text(
                reading.offset == 0
                    ? reading.text.trim()
                    : 'Resume · $progress%',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => Navigator.pop(context, reading),
              trailing: PopupMenuButton<String>(
                tooltip: 'Reading actions',
                onSelected: (action) =>
                    action == 'rename' ? _rename(reading) : _delete(reading),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'rename', child: Text('Rename')),
                  PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
            );
          },
        );
      },
    ),
  );
}
