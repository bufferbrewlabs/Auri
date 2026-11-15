import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../core/theme/app_theme.dart';
import '../features/read_aloud/data/delivery_suggestions.dart';
import '../features/read_aloud/domain/delivery_hint.dart';

class DeliveryHintsSheet extends StatefulWidget {
  const DeliveryHintsSheet({
    super.key,
    required this.text,
    required this.hints,
    required this.openAiKey,
    this.newClient = http.Client.new,
  });

  final String text;
  final List<DeliveryHint> hints;
  final String openAiKey;

  /// Makes the HTTP client for one suggestion request; replaced in tests.
  final http.Client Function() newClient;

  @override
  State<DeliveryHintsSheet> createState() => _DeliveryHintsSheetState();
}

class _DeliveryHintsSheetState extends State<DeliveryHintsSheet> {
  late final _key = TextEditingController(text: widget.openAiKey);
  late var _hints = [...widget.hints];
  http.Client? _client;
  String? _message;

  @override
  void dispose() {
    _client?.close();
    _key.dispose();
    super.dispose();
  }

  Future<void> _suggest() async {
    final key = _key.text.trim();
    if (key.isEmpty) {
      setState(() => _message = 'Enter an OpenAI API key.');
      return;
    }
    if (widget.text.length > 100000) {
      setState(
        () => _message = 'Suggestions support up to 100,000 characters.',
      );
      return;
    }
    final client = widget.newClient();
    setState(() {
      _client = client;
      _message = null;
    });
    try {
      final hints = await suggestDelivery(client, widget.text, key);
      if (!mounted) return;
      setState(() {
        _hints = hints;
        if (hints.isEmpty) _message = 'No delivery changes suggested.';
      });
    } on DeliverySuggestionException catch (e) {
      if (mounted) setState(() => _message = e.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _message = 'Could not get delivery suggestions. Try again.',
        );
      }
    } finally {
      client.close();
      if (mounted) setState(() => _client = null);
    }
  }

  void _toggleAll(bool enabled) {
    setState(
      () => _hints = [for (final hint in _hints) hint.withEnabled(enabled)],
    );
  }

  @override
  Widget build(BuildContext context) {
    final loading = _client != null;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Delivery hints', style: context.typography.title),
              const SizedBox(height: AppSpacing.sm),
              const Text(
                'Apply pauses, emphasis, slower speech or pronunciation changes to the Kokoro server voice.',
              ),
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: _key,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                enabled: !loading,
                decoration: const InputDecoration(labelText: 'OpenAI API key'),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextButton.icon(
                onPressed: loading ? null : _suggest,
                icon: const Icon(Icons.auto_awesome_outlined),
                label: Text(
                  loading
                      ? 'Getting suggestions…'
                      : 'Send text to OpenAI for suggestions',
                ),
              ),
              if (_message != null)
                Semantics(liveRegion: true, child: Text(_message!)),
              if (_hints.isNotEmpty) ...[
                Wrap(
                  children: [
                    TextButton(
                      onPressed: loading ? null : () => _toggleAll(true),
                      child: const Text('Enable all'),
                    ),
                    TextButton(
                      onPressed: loading ? null : () => _toggleAll(false),
                      child: const Text('Disable all'),
                    ),
                  ],
                ),
                for (var i = 0; i < _hints.length; i++)
                  SwitchListTile(
                    value: _hints[i].enabled,
                    title: Text('${_hints[i].summary} “${_hints[i].anchor}”'),
                    subtitle: Text(_hints[i].reason),
                    onChanged: loading
                        ? null
                        : (enabled) => setState(
                            () => _hints[i] = _hints[i].withEnabled(enabled),
                          ),
                  ),
                FilledButton(
                  onPressed: loading
                      ? null
                      : () => Navigator.pop(context, _hints),
                  child: const Text('Apply to reading'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
