import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:share_plus/share_plus.dart';
import 'appearance_settings.dart';
import 'core/theme/app_theme.dart';
import 'core/widgets/exit_confirm.dart';
import 'features/read_aloud/data/file_importer.dart';
import 'features/read_aloud/data/incoming_text.dart';
import 'features/read_aloud/data/reading_library.dart';
import 'features/read_aloud/data/reading_audio_cache.dart';
import 'features/read_aloud/domain/text_chunk.dart';
import 'features/read_aloud/domain/delivery_hint.dart';
import 'features/read_aloud/domain/reading_timeline.dart';
import 'features/read_aloud/domain/word_timing.dart';
import 'features/read_aloud/domain/voice_option.dart';
import 'features/read_aloud/domain/text_import.dart';
import 'features/read_aloud/selection_reader.dart';
import 'mp3.dart';
import 'on_device/local_kokoro.dart';
import 'settings_screen.dart';
import 'speech_api.dart';
import 'speech_preset.dart';
import 'ui/player_bar.dart';
import 'ui/delivery_hints_sheet.dart';
import 'ui/reading_view.dart';
import 'ui/reading_library_screen.dart';
import 'ui/voice_widgets.dart';
import 'voice_settings.dart';

/// "Read aloud" from another app's selection menu, run by
/// `ReadAloudService.kt` in a background engine with no screen.
@pragma('vm:entry-point')
Future<void> readAloudMain() => runSelectionReader();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb || IncomingText.supported) {
    try {
      await JustAudioBackground.init(
        androidNotificationChannelId: 'com.bufferbrew.auri.player',
        androidNotificationChannelName: 'Auri playback',
        androidNotificationIcon: 'drawable/ic_stat_read_aloud',
        androidStopForegroundOnPause: false,
      );
    } catch (_) {
      // Keep foreground reading available when the media session is unavailable.
    }
  }
  // Load saved settings before the first frame, so the app opens in your
  // theme and mode instead of flashing the defaults and switching (most
  // visible when it opens from Share).
  final store = DeviceSettingsStore();
  final settings = VoiceSettings(store: store);
  final appearance = AppearanceSettings(store: store);
  try {
    await Future.wait([
      settings.load(),
      appearance.load(),
    ]).timeout(const Duration(seconds: 2));
  } catch (_) {
    // Slow or unreadable storage: open with what has loaded so far.
  }
  runApp(AuriApp(settings: settings, appearance: appearance));
}

class AuriApp extends StatefulWidget {
  const AuriApp({super.key, this.settings, this.appearance});

  /// Injected by tests; the app makes its own on the device.
  final VoiceSettings? settings;
  final AppearanceSettings? appearance;

  @override
  State<AuriApp> createState() => _AuriAppState();
}

class _AuriAppState extends State<AuriApp> {
  late final _store = DeviceSettingsStore();
  late final VoiceSettings _settings =
      widget.settings ?? (VoiceSettings(store: _store)..load());
  late final AppearanceSettings _appearance =
      widget.appearance ?? (AppearanceSettings(store: _store)..load());

  @override
  void dispose() {
    if (widget.settings == null) _settings.dispose();
    if (widget.appearance == null) _appearance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _appearance,
    builder: (context, _) => MaterialApp(
      title: 'Auri',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.of(_appearance.palette, Brightness.light),
      darkTheme: AppTheme.of(_appearance.palette, Brightness.dark),
      themeMode: _appearance.themeMode,
      home: ExitConfirmScope(
        appName: 'Auri',
        child: ReaderScreen(settings: _settings, appearance: _appearance),
      ),
    ),
  );
}

class ReaderScreen extends StatefulWidget {
  const ReaderScreen({super.key, required this.settings, this.appearance});
  final VoiceSettings settings;
  final AppearanceSettings? appearance;
  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen>
    with WidgetsBindingObserver {
  VoiceSettings get s => widget.settings;
  final _text = TextEditingController();
  final _title = TextEditingController();
  final _incoming = IncomingText();

  /// Holds keyboard focus when no field does, so Ctrl/⌘+Enter always works.
  final _screenFocus = FocusNode(debugLabel: 'reader');
  FlutterTts? _tts;
  AudioPlayer? _audio;
  Completer<bool>? _audioWait;
  StreamSubscription<Duration>? _position;
  http.Client? _request;

  /// The finished reading as a file to export: MP3, or WAV from the phone.
  Uint8List? _mp3;
  bool _mp3IsWav = false;

  /// Kokoro on this phone, loaded on first use and kept while the app runs.
  LocalKokoroEngine? _engine;
  LocalModel? _engineModel;
  bool _playing = false, _busy = false;
  double _speed = 1;
  int _offset = 0, _session = 0;

  /// The word being spoken, when the device voice reports it.
  BodySpan? _word;

  /// How far through a generated MP3 playback is (Other API).
  Duration _audioPosition = Duration.zero;
  Duration? _apiDuration;
  TextChunk? _activeChunk;
  ReadingTimeline? _timeline;
  Engine? _timelineEngine;
  bool _forcedDevice = false;
  bool _readingDevice = false;
  bool _keepReader = false;
  List<DeliveryHint> _hints = [];
  final _audioCache = ReadingAudioCache();
  Timer? _saveProgress;
  late final _library = ReadingLibrary(s.store);
  String? _readingId;
  int? _savedOffset;
  bool _resumed = false;
  bool _savingReading = false;

  /// What's happening right now, shown under the voice while busy.
  String? _activity;

  /// A problem the user should read; warnings (offline) aren't errors.
  String? _notice;
  bool _noticeIsError = false;

  /// The voice reading now (or that read last), and why, if it's a fallback.
  VoiceSource? _source;
  String? _fallback;

  /// Kokoro audio already made this session, by voice and chunk text, so
  /// pausing and resuming doesn't synthesise the same chunk again.
  final _kokoroAudio = <String, CachedSpeech>{};

  bool get _locked => _playing || _busy;
  bool get _hasText => _text.text.trim().isNotEmpty;
  bool get _api => s.mode == ReadMode.api;
  bool get _showReader => _hasText && (_locked || _offset > 0 || _keepReader);

  void _activityIs(String? text) {
    if (mounted) setState(() => _activity = text);
  }

  void _warn(String message, {bool error = false}) {
    if (mounted) {
      setState(() {
        _notice = message;
        _noticeIsError = error;
        _activity = null;
      });
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  VoiceSource get _kokoroSource => VoiceSource(
    Icons.dns_outlined,
    'Kokoro · ${s.kokoroVoice}',
    s.kokoroHost.isEmpty ? 'Your Kokoro server' : 'From ${s.kokoroHost}',
  );

  String get _phoneVoice => localKokoroVoices.contains(s.kokoroVoice)
      ? s.kokoroVoice
      : localKokoroVoices[localKokoroSpeaker(s.kokoroVoice)];

  VoiceSource get _phoneSource => VoiceSource(
    Icons.memory_rounded,
    'Kokoro · $_phoneVoice',
    'On this phone · ${s.local.installed == LocalModel.compact ? 'compact' : 'full'} model',
  );

  VoiceSource get _deviceSource => VoiceSource(
    Icons.phone_android_rounded,
    s.deviceVoice == null ? 'Device voice' : 'Device · ${s.deviceVoice}',
    kIsWeb ? 'From this browser' : 'From this device',
  );

  VoiceSource get _apiSource => VoiceSource(
    Icons.cloud_outlined,
    '${presetSettings(s.apiPreset).label} · ${s.apiVoice.isEmpty ? 'no voice set' : s.apiVoice}',
    'From ${Uri.tryParse(s.apiEndpoint)?.host.nonEmpty ?? 'an endpoint you set'}',
  );

  /// The voice the next Read aloud would use.
  VoiceSource get _nextSource => switch (s.mode) {
    ReadMode.device => _deviceSource,
    ReadMode.api => _apiSource,
    ReadMode.kokoro => _kokoroSource,
    ReadMode.phone => _phoneSource,
    ReadMode.auto => switch (s.nextEngine) {
      Engine.phone => _phoneSource,
      Engine.server => _kokoroSource,
      _ => _deviceSource,
    },
  };

  double get _deviceRate =>
      (kIsWeb ? _speed : _speed * 0.5).clamp(0.1, kIsWeb ? 4.0 : 1.0);

  void _setSpeed(double value) {
    setState(() => _speed = value);
    unawaited(
      s.store.write('read_aloud.speed', '$value').catchError((Object _) {}),
    );
    // Applies at once to Kokoro and MP3s; the device voice from its next part.
    _audio?.setSpeed(value);
    _tts?.setSpeechRate(_deviceRate);
  }

  Future<void> _stop({bool reset = false}) async {
    _session++;
    _finishAudio();
    final player = _audio;
    final position = _position;
    _position = null;
    _activeChunk = null;
    _request?.close();
    _request = null;
    final tts = _tts;
    _tts = null;
    if (mounted) {
      setState(() {
        _playing = false;
        _busy = false;
        _activity = null;
        _word = null;
        if (reset) {
          _offset = 0;
          _keepReader = false;
        }
      });
    }
    if (reset) {
      _audioPosition = Duration.zero;
    }
    _updateSavedPlace();
    await Future.wait([
      if (tts != null) tts.stop(),
      if (player != null) player.stop(),
      if (position != null) position.cancel(),
    ]).catchError((Object _) => <Object?>[]);
  }

  void _togglePlay() {
    final player = _audio;
    final wait = _audioWait;
    if (player != null && wait != null && !wait.isCompleted && !_busy) {
      if (player.playing) {
        unawaited(player.pause());
      } else {
        _playPlayer(player, wait);
      }
    } else if (_locked) {
      _stop();
    } else if (_hasText) {
      _api && !_forcedDevice ? _playApi() : _readAloud();
    }
  }

  void _finishAudio() {
    final wait = _audioWait;
    _audioWait = null;
    if (wait != null && !wait.isCompleted) wait.complete(false);
  }

  void _playPlayer(AudioPlayer player, Completer<bool> wait) {
    unawaited(
      player.play().catchError((Object error, StackTrace stack) {
        if (!wait.isCompleted) wait.completeError(error, stack);
      }),
    );
  }

  Future<bool> _playLoadedAudio(AudioPlayer player) async {
    final session = _session;
    final wait = Completer<bool>();
    _audioWait = wait;
    final states = player.playerStateStream.listen((state) {
      if (!mounted || session != _session || wait.isCompleted) return;
      if (state.processingState == ProcessingState.completed) {
        wait.complete(true);
      } else if (state.playing != _playing) {
        setState(() {
          _playing = state.playing;
          _keepReader = true;
        });
        if (!state.playing) _updateSavedPlace();
      }
    });
    _playPlayer(player, wait);
    try {
      final completed = await wait.future;
      if (completed && session == _session) await player.pause();
      return completed;
    } finally {
      await states.cancel();
      if (_audioWait == wait) _audioWait = null;
    }
  }

  Future<Duration?> _loadAudio(
    AudioPlayer player,
    Uint8List bytes, {
    required String mimeType,
    required String id,
  }) => player.setAudioSource(
    AudioSource.uri(
      Uri.dataFromBytes(bytes, mimeType: mimeType),
      tag: MediaItem(
        id: id,
        title: _title.text.trim().isEmpty ? 'Read aloud' : _title.text.trim(),
        album: 'Auri',
      ),
    ),
  );

  /// Read aloud in the chosen mode. Automatic picks Kokoro when it answers,
  /// and the device voice when it doesn't.
  Future<void> _readAloud() async {
    if (!_hasText) return;
    _screenFocus.requestFocus();
    setState(() {
      _resumed = false;
      _fallback = null;
      _notice = null;
    });
    if (_forcedDevice) return _readDevice();
    final phoneReady = s.local.installed != null;
    switch (s.mode) {
      case ReadMode.device:
        return _readDevice();
      case ReadMode.phone:
        if (phoneReady) return _readPhone();
        _warn('Download a Kokoro model in Settings to read on this phone.');
        return;
      case ReadMode.auto when s.phoneFirst && phoneReady:
        return _readPhone();
      default:
        break;
    }
    setState(() => _busy = true);
    _activityIs('Checking Kokoro…');
    final session = ++_session;
    final cached = await _hasCachedKokoroStart();
    if (!mounted || session != _session) return;
    if (cached) return _readKokoro();
    final status = await s.checkKokoro();
    if (!mounted || session != _session) return;
    setState(() => _busy = false);
    if (status.isAvailable) return _readKokoro();
    if (s.mode == ReadMode.auto) {
      _fallback = 'Kokoro server ${status.short.toLowerCase()}';
      return phoneReady ? _readPhone() : _readDevice();
    }
    _warn(
      'Kokoro can’t read right now: ${status.label}',
      error: status.state == KokoroState.rejected,
    );
  }

  Future<void> _readDevice() async {
    final session = ++_session;
    final tts = FlutterTts();
    _tts = tts;
    setState(() {
      _playing = true;
      _source = _deviceSource;
      _readingDevice = true;
      _activity = null;
    });
    try {
      await tts.awaitSpeakCompletion(true);
      await tts.setSpeechRate(_deviceRate);
      // A fresh engine per session binds late callbacks to their original run.
      if (!mounted || session != _session) return;
      var from = _offset.clamp(0, _text.text.length);
      for (final chunk in chunkText(_text.text.substring(from))) {
        if (!mounted || session != _session) return;
        final start = from + chunk.start;
        setState(() => _offset = start);
        tts.setProgressHandler((
          String _,
          int wordStart,
          int wordEnd,
          String word,
        ) {
          if (mounted && session == _session) {
            setState(() {
              _offset = start + wordStart;
              _word = BodySpan(start + wordStart, start + wordEnd);
            });
          }
        });
        final result = await tts.speak(chunk.text);
        if (!mounted || session != _session) return;
        if (result == 0) {
          throw const SpeechException(
            'Device speech could not start. Install a system voice or try another browser.',
          );
        }
        _offset = from + chunk.end;
      }
      if (mounted && session == _session) {
        setState(() {
          _playing = false;
          _keepReader = false;
          _offset = 0;
          _word = null;
          _forcedDevice = false;
        });
        _updateSavedPlace();
        _toast('Finished reading');
      }
    } catch (_) {
      if (mounted && session == _session) {
        setState(() {
          _playing = false;
          _word = null;
        });
        _warn(
          'The device voice is unavailable. Install a system voice, or pick another voice.',
          error: true,
        );
      }
    }
  }

  String _serverKey(String endpoint, String voice, String input) =>
      'kokoro-captioned-v1\n$endpoint\n$voice\n$input';

  String _phoneKey(String voice, String input) =>
      'kokoro-phone-v1\n${s.local.installed?.name}\n$voice\n$input';

  String _apiKeyForAudio(String text) =>
      'other-api-v1\n${s.apiPreset.name}\n${s.apiEndpoint}\n'
      '${s.apiModel}\n${s.apiVoice}\n$text';

  Future<Uint8List> _speechChunk(
    String key,
    Future<CachedSpeech> Function() generate,
  ) async {
    final memory = _kokoroAudio[key];
    if (memory != null) return memory.audio;
    final id = _readingId;
    final stored = id == null ? null : await _audioCache.read(id, key);
    final speech = stored ?? await generate();
    if (stored == null && id != null && _readingId == id) {
      unawaited(_audioCache.write(id, key, speech));
    }
    _kokoroAudio[key] = speech;
    return speech.audio;
  }

  Future<bool> _hasCachedKokoroStart() async {
    final chunks = chunkText(_text.text);
    final id = _readingId;
    if (chunks.isEmpty || id == null) return false;
    final chunk = chunks.firstWhere(
      (c) => c.end > _offset,
      orElse: () => chunks.last,
    );
    final input = compileChunk(chunk, placeHints(_text.text, _hints));
    final key = _serverKey(s.kokoroEndpoint, s.kokoroVoice, input);
    if (_kokoroAudio.containsKey(key)) return true;
    final speech = await _audioCache.read(id, key);
    if (speech == null || id != _readingId) return false;
    _kokoroAudio[key] = speech;
    return true;
  }

  Future<Uint8List> _kokoroChunk(
    SpeechApi api,
    TextChunk chunk,
    String voice,
    List<PlacedHint> hints,
  ) {
    final input = compileChunk(chunk, hints);
    final endpoint = s.kokoroEndpoint;
    final token = s.kokoroToken;
    return _speechChunk(
      _serverKey(endpoint, voice, input),
      () => api.captioned(
        endpoint: endpoint,
        apiKey: token,
        voice: voice,
        text: input,
        useMarkup: input != chunk.text,
      ),
    );
  }

  Future<void> _readKokoro() async {
    final client = http.Client();
    _request = client;
    final api = SpeechApi(client);
    final voice = s.kokoroVoice;
    final hints = placeHints(_text.text, _hints);
    final endpoint = s.kokoroEndpoint;
    try {
      await _readChunks(
        engine: Engine.server,
        source: _kokoroSource,
        fetch: (chunk) => _kokoroChunk(api, chunk, voice, hints),
        words: (chunk) => alignWords(
          chunk,
          _kokoroAudio[_serverKey(endpoint, voice, compileChunk(chunk, hints))]
                  ?.timings ??
              const [],
        ),
        onError: (error) async {
          if (error is SpeechException &&
              (error.status == 401 || error.status == 403)) {
            _warn(
              'Kokoro rejected the token. Check it in Settings.',
              error: true,
            );
            return;
          }
          if (s.mode == ReadMode.auto) {
            s.markKokoroOffline();
            _fallback = 'Kokoro server stopped answering';
            await (s.local.installed != null && !s.phoneFirst
                ? _readPhone()
                : _readDevice());
          } else {
            _warn(
              error is SpeechException
                  ? error.message
                  : 'Can’t reach Kokoro. Check that the server is awake and online.',
              error: true,
            );
          }
        },
      );
    } finally {
      client.close();
      if (_request == client) _request = null;
    }
  }

  /// The on-device engine for the installed model, loading it if needed.
  Future<LocalKokoroEngine> _phoneEngine() async {
    final model = s.local.installed!;
    if (_engine != null && _engineModel == model) return _engine!;
    _engine?.dispose();
    _engine = null;
    final engine = await LocalKokoroEngine.start(
      await s.local.dirOf(model),
      model: model,
    );
    _engine = engine;
    _engineModel = model;
    return engine;
  }

  /// Kokoro on this phone: like the server path, the next piece is made
  /// while this one plays, and a whole reading becomes a WAV to export.
  Future<Uint8List> _phoneChunk(TextChunk chunk, String voice) =>
      _speechChunk(_phoneKey(voice, chunk.text), () async {
        final engine = await _phoneEngine();
        return (
          audio: await engine.speak(chunk.text, voice: voice),
          timings: const <WordTiming>[],
        );
      });

  Future<void> _readPhone() {
    final voice = _phoneVoice;
    return _readChunks(
      engine: Engine.phone,
      source: _phoneSource,
      fetch: (chunk) => _phoneChunk(chunk, voice),
      onError: (error) async {
        _engine?.dispose();
        _engine = null;
        if (s.mode == ReadMode.auto) {
          _fallback = 'Kokoro on this phone failed';
          await _readDevice();
        } else {
          _warn(
            error is LocalKokoroException
                ? error.message
                : 'Kokoro on this phone couldn’t read this.',
            error: true,
          );
        }
      },
    );
  }

  Future<void> _readChunks({
    required Engine engine,
    required VoiceSource source,
    required Future<Uint8List> Function(TextChunk) fetch,
    List<AlignedWord> Function(TextChunk)? words,
    required Future<void> Function(Object) onError,
  }) async {
    final session = ++_session;
    final wav = engine == Engine.phone;
    final timeline = _timelineEngine == engine && _timeline != null
        ? _timeline!
        : ReadingTimeline(
            wav ? phoneChunks(_text.text) : chunkText(_text.text),
          );
    final chunks = timeline.chunks;
    if (chunks.isEmpty) return;
    final from = _offset;
    final first = timeline.chunkAt(from).index;
    final parts = <Uint8List>[];
    setState(() {
      _readingDevice = false;
      _timeline = timeline;
      _timelineEngine = engine;
      _playing = true;
      _busy = true;
      _source = source;
      _word = null;
    });
    _activityIs(wav ? 'Preparing phone audio…' : 'Getting Kokoro audio…');

    Future<Uint8List> prefetch(TextChunk chunk) => fetch(chunk)..ignore();

    try {
      await _position?.cancel();
      final previous = _audio;
      _audio = null;
      await previous?.dispose();
      if (!mounted || session != _session) return;
      final player = AudioPlayer();
      _audio = player;
      var next = prefetch(chunks[first]);
      for (var i = first; i < chunks.length; i++) {
        final chunk = chunks[i];
        final bytes = await next;
        if (!mounted || session != _session) return;
        if (i + 1 < chunks.length) next = prefetch(chunks[i + 1]);
        parts.add(bytes);
        final duration = await _loadAudio(
          player,
          bytes,
          mimeType: wav ? 'audio/wav' : 'audio/mpeg',
          id: '$session-$i',
        );
        if (!mounted || session != _session) return;
        final aligned = words?.call(chunk) ?? const <AlignedWord>[];
        timeline.measure(chunk, duration, aligned);
        final start = i == first
            ? timeline.localTime(chunk, from)
            : Duration.zero;
        if (start > Duration.zero) await player.seek(start);
        await player.setSpeed(_speed);
        if (!mounted || session != _session) return;
        setState(() {
          _offset = i == first ? from : chunk.start;
          _audioPosition = start;
          _activeChunk = chunk;
          _busy = false;
          _activity = null;
        });
        final subscription = player.positionStream.listen((position) {
          if (!mounted || session != _session || _activeChunk != chunk) return;
          final active = activeWordAt(aligned, position);
          setState(() {
            _audioPosition = position;
            _offset = timeline.offsetAt(chunk, position);
            _word = active == null ? null : aligned[active].span;
          });
        });
        _position = subscription;
        final completed = await _playLoadedAudio(player);
        await subscription.cancel();
        if (!mounted || session != _session) return;
        _position = null;
        _activeChunk = null;
        if (!completed) {
          await _stop();
          return;
        }
        _offset = chunk.end;
      }
      setState(() {
        _playing = false;
        _keepReader = false;
        _offset = 0;
        _word = null;
        if (first == 0) {
          _mp3 = wav ? concatWav(parts) : concatMp3(parts);
          _mp3IsWav = wav;
        }
      });
      unawaited(player.stop());
      _updateSavedPlace();
      _toast(
        first == 0 ? 'Finished · audio ready to export' : 'Finished reading',
      );
    } catch (error) {
      if (!mounted || session != _session) return;
      await _position?.cancel();
      if (!mounted || session != _session) return;
      _position = null;
      _activeChunk = null;
      setState(() {
        _playing = false;
        _busy = false;
        _activity = null;
      });
      await onError(error);
    }
  }

  /// Other API: generate the MP3 if there isn't one, then play it.
  Future<void> _playApi() async {
    _screenFocus.requestFocus();
    setState(() {
      _readingDevice = false;
      _resumed = false;
      _notice = null;
      _fallback = null;
    });
    if (_mp3 == null) {
      final session = _session + 1;
      await _generate();
      if (session != _session) return;
    }
    if (_mp3 != null && mounted) await _playMp3();
  }

  Future<void> _generate() async {
    final session = ++_session;
    final client = http.Client();
    _request = client;
    setState(() {
      _busy = true;
      _mp3 = null;
      _source = _apiSource;
      _readingDevice = false;
    });
    _activityIs('Generating audio…');
    try {
      final text = _text.text;
      final endpoint = s.apiEndpoint;
      final apiKey = s.apiKey;
      final model = s.apiModel;
      final voice = s.apiVoice;
      final bytes = await _speechChunk(_apiKeyForAudio(text), () async {
        final audio = await SpeechApi(client).generate(
          text: text,
          endpoint: endpoint,
          apiKey: apiKey,
          model: model,
          voice: voice,
          onProgress: (done, total) {
            if (session == _session && total > 1) {
              _activityIs('Generating audio · part ${done + 1} of $total');
            }
          },
        );
        return (audio: audio, timings: const <WordTiming>[]);
      });
      if (!mounted || session != _session) return;
      setState(() {
        _mp3 = bytes;
        _mp3IsWav = false;
      });
    } on SpeechException catch (e) {
      if (session == _session) _warn(e.message, error: e.status != null);
    } catch (_) {
      if (session == _session) {
        _warn(
          'Can’t reach the speech provider. Check your connection and endpoint'
          '${kIsWeb ? '; web providers must allow CORS' : ''}.',
        );
      }
    } finally {
      client.close();
      if (mounted && session == _session) {
        setState(() {
          _busy = false;
          _request = null;
          _activity = null;
        });
      }
    }
  }

  Future<void> _playMp3() async {
    final session = ++_session;
    setState(() {
      _playing = true;
      _busy = true;
    });
    try {
      await _position?.cancel();
      final previous = _audio;
      _audio = null;
      await previous?.dispose();
      if (!mounted || session != _session) return;
      final player = AudioPlayer();
      _audio = player;
      final total = await _loadAudio(
        player,
        _mp3!,
        mimeType: 'audio/mpeg',
        id: '$session',
      );
      await player.setSpeed(_speed);
      if (!mounted || session != _session) return;
      final start = total == null
          ? Duration.zero
          : _audioPosition > Duration.zero
          ? _audioPosition
          : total * (_offset / _text.text.length).clamp(0, 1);
      if (start > Duration.zero) await player.seek(start);
      if (!mounted || session != _session) return;
      setState(() {
        _apiDuration = total;
        _audioPosition = start;
        _busy = false;
      });
      _position = player.positionStream.listen((position) {
        final ms = total?.inMilliseconds ?? 0;
        if (mounted && session == _session && ms > 0) {
          setState(() {
            _audioPosition = position;
            _offset =
                (_text.text.length * (position.inMilliseconds / ms).clamp(0, 1))
                    .floor();
          });
        }
      });
      final completed = await _playLoadedAudio(player);
      if (mounted && session == _session) {
        await _position?.cancel();
        if (!mounted || session != _session) return;
        _position = null;
        setState(() {
          _playing = false;
          if (completed) {
            _keepReader = false;
            _offset = 0;
            _audioPosition = Duration.zero;
          }
        });
        if (completed) {
          unawaited(player.stop());
          _updateSavedPlace();
          _toast('Finished playing');
        }
      }
    } catch (_) {
      if (mounted && session == _session) {
        setState(() {
          _playing = false;
          _busy = false;
        });
        _warn(
          'Audio playback failed. You can still export the MP3.',
          error: true,
        );
      }
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (!mounted) return;
    if (text.isEmpty) {
      _toast('The clipboard has no text');
      return;
    }
    setState(() {
      _detachReading();
      _text.text = text;
      _offset = 0;
      _mp3 = null;
    });
  }

  Future<void> _import() async {
    if (_locked || _audioWait != null) await _stop();
    setState(() => _busy = true);
    _activityIs('Opening the document…');
    try {
      final file = await const FileImporter().pick();
      if (file == null || !mounted) return;
      if (file.text.body.trim().isEmpty) {
        throw const ImportException('This file contains no readable text.');
      }
      setState(() {
        _detachReading();
        _title.text = file.text.title;
        _text.text = file.text.body;
        _offset = 0;
        _mp3 = null;
        _notice = null;
      });
      _toast('Imported ${file.text.title}');
    } on ImportException catch (e) {
      _warn(e.message, error: true);
    } catch (_) {
      _warn(
        'This file could not be read. Try a TXT, Markdown, PDF, or EPUB file.',
        error: true,
      );
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _activity = null;
        });
      }
    }
  }

  SavedReading _snapshot(String id) => SavedReading(
    id: id,
    title: _title.text,
    text: _text.text,
    offset: _offset,
    hints: _hints,
  );

  Future<void> _saveReading() async {
    if (_savingReading) return;
    _savingReading = true;
    final id = _readingId ?? DateTime.now().microsecondsSinceEpoch.toString();
    final reading = _snapshot(id);
    try {
      await _library.save(reading);
      if (!mounted || _text.text != reading.text) return;
      _readingId = id;
      _savedOffset = reading.offset;
      _cacheSavedReading(reading);
      _toast('Saved on this device');
    } catch (_) {
      if (mounted) {
        _warn('Could not save the reading on this device.', error: true);
      }
    } finally {
      _savingReading = false;
    }
  }

  void _cacheSavedReading(SavedReading reading) {
    final hints = placeHints(reading.text, reading.hints);
    final keys = [
      _apiKeyForAudio(reading.text),
      for (final chunk in chunkText(reading.text))
        _serverKey(s.kokoroEndpoint, s.kokoroVoice, compileChunk(chunk, hints)),
      if (s.local.installed != null)
        for (final chunk in phoneChunks(reading.text))
          _phoneKey(_phoneVoice, chunk.text),
    ];
    for (final key in keys) {
      if (_kokoroAudio[key] case final speech?) {
        unawaited(_audioCache.write(reading.id, key, speech));
      }
    }
  }

  void _updateSavedPlace() {
    final id = _readingId;
    if (id == null || _savedOffset == _offset) return;
    final reading = _snapshot(id);
    _savedOffset = reading.offset;
    unawaited(
      _library.save(reading).catchError((Object _) {
        if (_readingId == id && _savedOffset == reading.offset) {
          _savedOffset = null;
        }
      }),
    );
  }

  void _detachReading() {
    _readingId = null;
    _savedOffset = null;
    _resumed = false;
    _hints = [];
    _forcedDevice = false;
    _keepReader = false;
    _timeline = null;
    _apiDuration = null;
    _audioPosition = Duration.zero;
  }

  Future<void> _openLibrary() async {
    if (_locked || _audioWait != null) await _stop();
    _updateSavedPlace();
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    final reading = await Navigator.of(context).push<SavedReading>(
      MaterialPageRoute(
        builder: (_) => ReadingLibraryScreen(
          library: _library,
          onDelete: (id) {
            if (_readingId == id) _readingId = null;
            unawaited(_audioCache.deleteReading(id));
          },
          onRename: (renamed) {
            if (_readingId == renamed.id) _title.text = renamed.title;
          },
        ),
      ),
    );
    if (!mounted) return;
    if (reading == null) {
      setState(() {});
      return;
    }
    setState(() {
      _detachReading();
      _title.text = reading.title;
      _text.text = reading.text;
      _readingId = reading.id;
      _savedOffset = _offset = reading.offset;
      _resumed = _offset > 0;
      _hints = reading.hints;
      _mp3 = null;
      _word = null;
      _notice = null;
      _fallback = null;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _updateSavedPlace();
  }

  Future<void> _useDeviceVoice() async {
    await _stop();
    if (!mounted || !_hasText) return;
    _forcedDevice = true;
    _notice = null;
    _fallback = null;
    _readDevice();
  }

  Future<void> _openHints() async {
    final text = _text.text;
    final hints = await showModalBottomSheet<List<DeliveryHint>>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => DeliveryHintsSheet(
        text: text,
        hints: _hints,
        openAiKey: s.apiPreset == SpeechPreset.openai ? s.apiKey : '',
      ),
    );
    if (!mounted || hints == null || text != _text.text) return;
    final resume = _playing;
    await _stop();
    if (!mounted || text != _text.text) return;
    setState(() {
      _hints = hints;
      _timeline = null;
      _mp3 = null;
      _savedOffset = null;
    });
    _updateSavedPlace();
    if (resume) _togglePlay();
  }

  bool get _canExport =>
      _hasText &&
      !_locked &&
      (_mp3 != null ||
          (!_forcedDevice && _nextSource.icon != _deviceSource.icon));

  Future<void> _generateExport() async {
    if (_api) return _generate();
    final phone =
        s.mode == ReadMode.phone ||
        (s.mode == ReadMode.auto && s.nextEngine == Engine.phone);
    final chunks = phone ? phoneChunks(_text.text) : chunkText(_text.text);
    final voice = phone ? _phoneVoice : s.kokoroVoice;
    final hints = placeHints(_text.text, _hints);
    final session = ++_session;
    final client = http.Client();
    _request = client;
    final api = SpeechApi(client);
    final parts = <Uint8List>[];
    setState(() => _busy = true);
    try {
      for (final chunk in chunks) {
        _activityIs(
          'Preparing export · part ${chunk.index + 1} of ${chunks.length}',
        );
        final bytes = await (phone
            ? _phoneChunk(chunk, voice)
            : _kokoroChunk(api, chunk, voice, hints));
        if (!mounted || session != _session) return;
        parts.add(bytes);
      }
      setState(() {
        _mp3 = phone ? concatWav(parts) : concatMp3(parts);
        _mp3IsWav = phone;
      });
    } catch (e) {
      if (mounted && session == _session) {
        _warn(
          e is SpeechException ? e.message : 'Could not prepare the export.',
          error: true,
        );
      }
    } finally {
      client.close();
      if (_request == client) _request = null;
      if (mounted && session == _session) {
        setState(() {
          _busy = false;
          _activity = null;
        });
      }
    }
  }

  Future<void> _export({bool share = false}) async {
    final text = _text.text;
    if (_mp3 == null) await _generateExport();
    final bytes = _mp3;
    if (!mounted || bytes == null || text != _text.text) return;
    final title = _title.text.trim();
    final mimeType = _mp3IsWav ? 'audio/wav' : 'audio/mpeg';
    final mp3Name = mp3FileName(title.isEmpty ? 'Auri' : title);
    final fileName = _mp3IsWav
        ? mp3Name.replaceFirst(RegExp(r'\.mp3$'), '.wav')
        : mp3Name;
    try {
      if (share) {
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile.fromData(bytes, mimeType: mimeType, name: fileName)],
            fileNameOverrides: [fileName],
          ),
        );
      } else {
        final saved = await FilePicker.saveFile(
          fileName: fileName,
          bytes: bytes,
          mimeType: mimeType,
        );
        if (mounted && saved != null) {
          _toast(mimeType == 'audio/wav' ? 'WAV exported' : 'MP3 exported');
        }
      }
    } catch (_) {
      if (mounted) {
        _warn('The audio could not be exported. Try again.', error: true);
      }
    }
  }

  void _invalidate() => setState(() {
    _detachReading();
    _mp3 = null;
    _offset = 0;
    _word = null;
  });

  void _clear() {
    _text.clear();
    _title.clear();
    _invalidate();
  }

  Object? _lastVoiceConfiguration;
  Object get _voiceConfiguration => (
    s.mode,
    s.kokoroEndpoint,
    s.kokoroVoice,
    s.local.installed,
    s.apiPreset,
    s.apiEndpoint,
    s.apiModel,
    s.apiVoice,
  );

  void _settingsChanged() {
    if (!mounted) return;
    setState(() {
      final configuration = _voiceConfiguration;
      if (_lastVoiceConfiguration != configuration && !_locked) {
        _timeline = null;
        _apiDuration = null;
        _audioPosition = Duration.zero;
        _mp3 = null;
        _word = null;
        _forcedDevice = false;
        _notice = null;
        _fallback = null;
      }
      _lastVoiceConfiguration = configuration;
      // A deleted or swapped model: let the old engine go.
      if (_engineModel != null && s.local.installed != _engineModel) {
        _engine?.dispose();
        _engine = null;
        _engineModel = null;
      }
    });
  }

  Future<void> _openSettings() async {
    if (_locked || _audioWait != null) await _stop();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            SettingsScreen(settings: s, appearance: widget.appearance),
      ),
    );
  }

  Future<void> _openVoiceSheet() async {
    final resume = _playing;
    if (_locked || _audioWait != null) await _stop();
    if (!mounted) return;
    s.checkKokoro();
    final session = _session;
    final showSettings = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            0,
            AppSpacing.md,
            AppSpacing.lg,
          ),
          child: ListenableBuilder(
            listenable: s,
            builder: (context, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm,
                  ),
                  child: Text('Voice', style: context.typography.title),
                ),
                const SizedBox(height: AppSpacing.sm),
                ReadModePicker(settings: s),
                if (s.mode != ReadMode.device && s.mode != ReadMode.api)
                  if (s.voiceChoices case final choices?) ...[
                    const SizedBox(height: AppSpacing.sm),
                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      initialValue: choices.contains(s.kokoroVoice)
                          ? s.kokoroVoice
                          : null,
                      decoration: const InputDecoration(
                        labelText: 'Kokoro voice',
                      ),
                      items: [
                        for (final voice in choices)
                          DropdownMenuItem(
                            value: voice,
                            child: Text(
                              VoiceOption(voice).label,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (voice) {
                        if (voice == null) return;
                        s.kokoroVoice = voice;
                        Navigator.pop(sheet);
                      },
                    ),
                  ],
                const SizedBox(height: AppSpacing.sm),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () => Navigator.of(sheet).pop(true),
                    icon: const Icon(Icons.tune_rounded, size: 18),
                    label: const Text('Voice settings'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!mounted || session != _session) return;
    if (showSettings == true) await _openSettings();
    if (!mounted || session != _session) return;
    if (resume) _togglePlay();
  }

  String _lastText = '';
  void _textChanged() {
    if (_text.text == _lastText) return;
    _lastText = _text.text;
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _saveProgress = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _updateSavedPlace(),
    );
    unawaited(
      s.store
          .read('read_aloud.speed')
          .then((value) {
            final speed = double.tryParse(value ?? '');
            if (mounted &&
                speed != null &&
                speed.isFinite &&
                _speed == 1 &&
                !_locked) {
              setState(() => _speed = speed.clamp(0.25, 3));
            }
          })
          .catchError((Object _) {}),
    );
    _lastVoiceConfiguration = _voiceConfiguration;
    s.addListener(_settingsChanged);
    _text.addListener(_textChanged);
    _incoming.listen(_readIncoming);
  }

  /// Text shared from another app: read it at
  /// once with the device voice, whatever the mode. A quick selection
  /// shouldn't wait on Kokoro or spend on an API.
  ///
  /// Whatever was playing is cut off without a frame in between, so the
  /// screen goes straight from one reading to the next.
  void _readIncoming(String text, String? subject) {
    if (!mounted) return;
    _session++;
    _finishAudio();
    _position?.cancel();
    _position = null;
    _activeChunk = null;
    _updateSavedPlace();
    _request?.close();
    _request = null;
    _tts?.stop();
    _tts = null;
    _audio?.stop();
    setState(() {
      _detachReading();
      _forcedDevice = true;
      _title.text = subject ?? 'Selected text';
      _text.text = text.trim();
      _offset = 0;
      _mp3 = null;
      _word = null;
      _notice = null;
      _activity = null;
      _fallback = 'selected text uses the device voice';
      _playing = false;
      _busy = false;
    });
    _readDevice();
  }

  @override
  void dispose() {
    _updateSavedPlace();
    WidgetsBinding.instance.removeObserver(this);
    _saveProgress?.cancel();
    s.removeListener(_settingsChanged);
    _incoming.dispose();
    _engine?.dispose();
    _session++;
    _finishAudio();
    _request?.close();
    _tts?.stop();
    _position?.cancel();
    _audio?.dispose();
    _text.dispose();
    _title.dispose();
    _screenFocus.dispose();
    super.dispose();
  }

  bool get _canSeek => _showReader && !_busy && _hasText;
  bool get _timed =>
      !_forcedDevice &&
      (_api ? _apiDuration != null : _timeline != null && !_readingDevice);

  Duration? get _total => !_timed
      ? null
      : _api
      ? _apiDuration
      : _timeline?.total;

  Duration get _elapsed {
    if (!_timed) return Duration.zero;
    if (_api) return _audioPosition;
    return _timeline!.elapsed(
      _offset,
      active: _activeChunk,
      position: _activeChunk == null ? null : _audioPosition,
    );
  }

  Future<void> _seekOffset(int offset) async {
    if (!_canSeek) return;
    final text = _text.text;
    var target = offset.clamp(0, text.length - 1);
    // A slider can land inside a word (or a UTF-16 surrogate pair).
    while (target > 0 && !RegExp(r'\s').hasMatch(text[target - 1])) {
      target--;
    }
    final player = _audio;
    final timeline = _timeline;
    final chunk = _activeChunk;
    if (_timed && player != null && _audioWait != null) {
      if (_api) {
        await player.seek(_apiDuration! * (target / text.length));
        return;
      }
      if (chunk != null &&
          timeline != null &&
          chunk == timeline.chunkAt(target)) {
        await player.seek(timeline.localTime(chunk, target));
        return;
      }
    }
    final wasPlaying = _playing;
    final session = _session + 1;
    await _stop();
    if (!mounted || session != _session || text != _text.text) return;
    setState(() {
      _offset = target;
      _keepReader = true;
      _word = null;
      if (_apiDuration case final duration?) {
        _audioPosition = duration * (target / text.length);
      }
    });
    _updateSavedPlace();
    if (wasPlaying) _togglePlay();
  }

  Future<void> _seekTime(Duration target) async {
    if (!_canSeek || !_timed) return;
    final total = _total!;
    if (total <= Duration.zero) return;
    final time = Duration(
      microseconds: target.inMicroseconds.clamp(0, total.inMicroseconds - 1),
    );
    final player = _audio;
    if (_api) {
      if (player != null && _audioWait != null) {
        await player.seek(time);
      } else {
        setState(() {
          _audioPosition = time;
          _offset =
              (_text.text.length * time.inMicroseconds / total.inMicroseconds)
                  .floor();
        });
        _updateSavedPlace();
      }
      return;
    }
    final timeline = _timeline!;
    final active = _activeChunk;
    if (player != null && _audioWait != null && active != null) {
      final position = time - timeline.elapsed(active.start);
      if (position >= Duration.zero && position < timeline.duration(active)) {
        await player.seek(position);
        return;
      }
    }
    await _seekOffset(timeline.seek(time));
  }

  void _seekFraction(double fraction) {
    final total = _total;
    if (total == null) {
      _seekOffset((_text.text.length * fraction).floor());
    } else {
      _seekTime(total * fraction);
    }
  }

  void _skipSpan(List<BodySpan> spans, int direction, {bool restart = false}) {
    if (spans.isEmpty) return;
    final index = spans.indexWhere((p) => p.end > _offset);
    final current = index < 0 ? spans.length - 1 : index;
    final at = restart
        ? current
        : (current + direction).clamp(0, spans.length - 1);
    _seekOffset(spans[at].start);
  }

  void _paragraph(int direction) {
    final paragraphs = paragraphRanges(_text.text);
    final index = paragraphs.indexWhere((p) => p.end > _offset);
    final restart =
        direction == 0 ||
        (direction < 0 && index >= 0 && _offset - paragraphs[index].start > 30);
    _skipSpan(paragraphs, direction, restart: restart);
  }

  Future<void> _chooseParagraph() async {
    final paragraphs = paragraphRanges(_text.text);
    final offset = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: ListView.builder(
          itemCount: paragraphs.length,
          itemBuilder: (context, i) {
            final p = paragraphs[i];
            return ListTile(
              title: Text('Paragraph ${i + 1}'),
              subtitle: Text(
                _text.text.substring(p.start, p.end).trim(),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              selected: p.contains(_offset),
              onTap: () => Navigator.pop(sheet, p.start),
            );
          },
        ),
      ),
    );
    if (offset != null && mounted) await _seekOffset(offset);
  }

  Map<ShortcutActivator, VoidCallback> get _readerKeys => {
    const CharacterActivator(' '): _togglePlay,
    const CharacterActivator('k'): _togglePlay,
    const CharacterActivator('j'): () =>
        _seekTime(_elapsed - const Duration(seconds: 10)),
    const CharacterActivator('l'): () =>
        _seekTime(_elapsed + const Duration(seconds: 10)),
    const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
        _seekTime(_elapsed - const Duration(seconds: 5)),
    const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
        _seekTime(_elapsed + const Duration(seconds: 5)),
    const CharacterActivator('P'): () => _paragraph(-1),
    const CharacterActivator('N'): () => _paragraph(1),
    const CharacterActivator('r'): () => _paragraph(0),
    const CharacterActivator(','): () =>
        _skipSpan(sentenceRanges(_text.text), -1),
    const CharacterActivator('.'): () =>
        _skipSpan(sentenceRanges(_text.text), 1),
    const CharacterActivator('<'): () =>
        _setSpeed((_speed - 0.25).clamp(0.25, 3)),
    const CharacterActivator('>'): () =>
        _setSpeed((_speed + 0.25).clamp(0.25, 3)),
    const SingleActivator(LogicalKeyboardKey.home): () => _seekFraction(0),
    for (var d = 0; d <= 9; d++)
      CharacterActivator('$d'): () => _seekFraction(d / 10),
  };

  String get _subtitle {
    if (_activity != null) return _activity!;
    final source = _locked && _source != null ? _source! : _nextSource;
    return _fallback == null ? source.origin : '${source.origin} · $_fallback';
  }

  String? get _readerStatus {
    final length = _text.text.length;
    if (_api && !_readingDevice) return _playing ? 'Playing the MP3' : null;
    if (length == 0) return null;
    final pct = (_offset / length * 100).clamp(0, 100).round();
    return _playing ? 'Reading · $pct%' : 'Paused · $pct%';
  }

  @override
  Widget build(BuildContext context) {
    final source = _locked && _source != null ? _source! : _nextSource;
    final length = _text.text.length;
    final total = _total;
    final elapsed = _elapsed;
    final paragraphs = _canSeek
        ? paragraphRanges(_text.text)
        : const <BodySpan>[];
    final currentParagraph = paragraphs.indexWhere((p) => p.end > _offset);
    final progress = total != null && total > Duration.zero
        ? (elapsed.inMicroseconds / total.inMicroseconds).clamp(0.0, 1.0)
        : length == 0
        ? 0.0
        : (_offset / length).clamp(0.0, 1.0);
    return CallbackShortcuts(
      bindings: {
        if (_showReader) ..._readerKeys,
        const SingleActivator(LogicalKeyboardKey.enter, control: true):
            _togglePlay,
        const SingleActivator(LogicalKeyboardKey.enter, meta: true):
            _togglePlay,
      },
      child: Focus(
        focusNode: _screenFocus,
        autofocus: true,
        child: Scaffold(
          appBar: AppBar(
            titleSpacing: AppSpacing.lg,
            title: Row(
              children: [
                ClipRRect(
                  borderRadius: AppRadius.smAll,
                  child: Image.asset(
                    'assets/branding/logo.png',
                    width: 28,
                    height: 28,
                    excludeFromSemantics: true,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm + AppSpacing.xxs),
                const Text('Auri'),
              ],
            ),
            actions: [
              IconButton(
                tooltip: 'Saved readings',
                onPressed: _openLibrary,
                icon: const Icon(Icons.bookmarks_outlined),
              ),
              IconButton(
                tooltip: 'Import document',
                onPressed: _locked ? null : _import,
                icon: const Icon(Icons.file_open_outlined),
              ),
              IconButton(
                tooltip: 'Settings',
                onPressed: _openSettings,
                icon: const Icon(Icons.settings_outlined),
              ),
              const SizedBox(width: AppSpacing.xs),
            ],
          ),
          body: Column(
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (context, box) {
                    final gutter = AppSpacing.gutter(box.maxWidth);
                    final padding = EdgeInsets.fromLTRB(
                      gutter,
                      AppSpacing.md,
                      gutter,
                      AppSpacing.lg,
                    );
                    return Align(
                      alignment: Alignment.topCenter,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: AppBreakpoints.readingMaxWidth + 2 * gutter,
                        ),
                        child: AnimatedSwitcher(
                          duration: AppMotion.of(context, AppMotion.fast),
                          child: _showReader
                              ? ReadingView(
                                  key: const ValueKey('reader'),
                                  title: _title.text,
                                  text: _text.text,
                                  offset: _offset,
                                  word: _word,
                                  highlight: !_api || _readingDevice,
                                  onSeek: _canSeek ? _seekOffset : null,
                                  status: _readerStatus,
                                  onEdit: _locked
                                      ? null
                                      : () => _stop(reset: true),
                                  padding: padding,
                                )
                              : _Editor(
                                  key: const ValueKey('editor'),
                                  title: _title,
                                  text: _text,
                                  enabled: !_locked,
                                  padding: padding,
                                  onPaste: _paste,
                                  onImport: _import,
                                  onChanged: _invalidate,
                                ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              if (_resumed)
                ListTile(
                  title: const Text('Resumed from your saved place'),
                  leading: const Icon(Icons.bookmark_outline),
                  onTap: () => setState(() => _resumed = false),
                  trailing: TextButton(
                    onPressed: () {
                      setState(() => _resumed = false);
                      _stop(reset: true);
                    },
                    child: const Text('Start over'),
                  ),
                ),
              if (_notice != null)
                NoticeBanner(
                  message: _notice!,
                  error: _noticeIsError,
                  onDismiss: () => setState(() => _notice = null),
                ),
            ],
          ),
          bottomNavigationBar: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: PlayerBar(
              source: source,
              subtitle: _subtitle,
              progress: progress,
              onSeek: _canSeek ? _seekFraction : null,
              elapsed: elapsed,
              total: total,
              estimated: !_api && (_timeline?.estimated ?? false),
              onParagraphs: _canSeek ? _chooseParagraph : null,
              paragraphLabel: paragraphs.isEmpty
                  ? null
                  : '${currentParagraph < 0 ? paragraphs.length : currentParagraph + 1} / ${paragraphs.length}',
              onPrevious: _canSeek ? () => _paragraph(-1) : null,
              onNext: _canSeek ? () => _paragraph(1) : null,
              onBack: _canSeek && _timed
                  ? () => _seekTime(elapsed - const Duration(seconds: 10))
                  : null,
              onForward: _canSeek && _timed
                  ? () => _seekTime(elapsed + const Duration(seconds: 10))
                  : null,
              playing: _playing,
              busy: _busy,
              playTooltip: _api
                  ? (_mp3 == null ? 'Generate and play' : 'Play')
                  : (_offset > 0 ? 'Resume' : 'Read aloud'),
              onPlay: _hasText ? _togglePlay : null,
              onPause: _togglePlay,
              speed: _speed,
              onSpeed: _setSpeed,
              onVoiceTap: _openVoiceSheet,
              actions: [
                PlayerAction(
                  'Save reading on this device',
                  Icons.bookmark_add_outlined,
                  _hasText ? _saveReading : null,
                ),
                PlayerAction(
                  (_mp3 != null
                          ? _mp3IsWav
                          : _nextSource.icon == _phoneSource.icon)
                      ? 'Export WAV'
                      : 'Export MP3',
                  Icons.download_rounded,
                  _canExport ? _export : null,
                ),
                PlayerAction(
                  'Share audio',
                  Icons.share_outlined,
                  _canExport ? () => _export(share: true) : null,
                ),
                PlayerAction(
                  'Delivery hints',
                  Icons.auto_awesome_outlined,
                  _hasText && !_busy ? _openHints : null,
                ),
                PlayerAction(
                  'Retry playback',
                  Icons.refresh_rounded,
                  _hasText && !_locked && _notice != null ? _togglePlay : null,
                ),
                PlayerAction(
                  'Use device voice',
                  Icons.record_voice_over_outlined,
                  _hasText &&
                          !_busy &&
                          !_readingDevice &&
                          _nextSource.icon != _deviceSource.icon
                      ? _useDeviceVoice
                      : null,
                ),
                PlayerAction(
                  'Start over',
                  Icons.replay_rounded,
                  _offset > 0 && !_locked ? () => _stop(reset: true) : null,
                ),
                PlayerAction(
                  'Clear text',
                  Icons.delete_outline_rounded,
                  _hasText && !_locked ? _clear : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Writing surface: a title, the text, and — while empty — the two ways in.
class _Editor extends StatelessWidget {
  const _Editor({
    super.key,
    required this.title,
    required this.text,
    required this.enabled,
    required this.padding,
    required this.onPaste,
    required this.onImport,
    required this.onChanged,
  });

  final TextEditingController title;
  final TextEditingController text;
  final bool enabled;
  final EdgeInsets padding;
  final VoidCallback onPaste;
  final VoidCallback onImport;
  final VoidCallback onChanged;

  static const _plain = InputDecoration(
    filled: false,
    border: InputBorder.none,
    enabledBorder: InputBorder.none,
    focusedBorder: InputBorder.none,
    disabledBorder: InputBorder.none,
    contentPadding: EdgeInsets.zero,
    isCollapsed: true,
  );

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = context.typography;
    final words = RegExp(r'\S+').allMatches(text.text).length;
    final minutes = (words / 170).ceil();
    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: title,
            enabled: enabled,
            style: t.headline,
            textInputAction: TextInputAction.next,
            decoration: _plain.copyWith(
              hintText: 'Untitled',
              hintStyle: t.headline.copyWith(color: c.textTertiary),
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            words == 0
                ? 'Paste or write something, then press play.'
                : '$words ${words == 1 ? 'word' : 'words'} · about $minutes min to listen',
            style: t.bodySmall.copyWith(color: c.textSecondary),
          ),
          if (words == 0) ...[
            const SizedBox(height: AppSpacing.lg),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                OutlinedButton.icon(
                  onPressed: enabled ? onPaste : null,
                  icon: const Icon(Icons.content_paste_rounded, size: 18),
                  label: const Text('Paste'),
                ),
                OutlinedButton.icon(
                  onPressed: enabled ? onImport : null,
                  icon: const Icon(Icons.file_open_outlined, size: 18),
                  label: const Text('Import document'),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'TXT, Markdown, PDF with text or EPUB',
              style: t.caption.copyWith(color: c.textTertiary),
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          Expanded(
            child: TextField(
              controller: text,
              enabled: enabled,
              expands: true,
              maxLines: null,
              minLines: null,
              textAlignVertical: TextAlignVertical.top,
              keyboardType: TextInputType.multiline,
              style: t.reading,
              decoration: _plain.copyWith(
                hintText: 'Text to read',
                hintStyle: t.reading.copyWith(color: c.textTertiary),
              ),
              onChanged: (_) => onChanged(),
            ),
          ),
        ],
      ),
    );
  }
}

extension on String {
  String? get nonEmpty => isEmpty ? null : this;
}
