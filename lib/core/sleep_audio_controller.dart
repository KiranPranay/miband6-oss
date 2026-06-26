import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import '../storage/snore_store.dart';
import 'logger.dart';
import 'snore_detector.dart';

enum SleepAudioState { idle, requesting, denied, listening, error }

/// Opt-in, on-device microphone snoring detection.
///
/// PRIVACY: the PCM stream from `record` is reduced to per-window energy
/// features in memory and discarded immediately. This class writes NO audio to
/// disk and makes NO network call. Only derived [SnoreEvent]s (times + loudness)
/// are surfaced. The mic runs only inside an explicitly started session, behind
/// a microphone foreground service whose notification is the active indicator.
class SleepAudioController extends ChangeNotifier {
  final BLELogger _logger;
  SleepAudioController(this._logger) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onStopRequested') {
        await stop();
      }
      return null;
    });
    _store.load().then((_) {
      lastSession = _store.latest;
      notifyListeners();
    });
  }

  final SnoreStore _store = SnoreStore();

  /// The most recent persisted session (survives app restarts). Null until a
  /// session has been recorded.
  SnoreSession? lastSession;

  static const MethodChannel _channel = MethodChannel('band/sleep_audio');
  static const int _sampleRate = 8000; // enough for snore band; saves battery
  static const SnoreConfig _cfg = SnoreConfig();
  static const int _windowSamples = 8000 * 3; // 3-second windows
  // One-pole low-pass coefficient for a ~500 Hz cut at 8 kHz (band-energy proxy).
  static const double _lpAlpha = 0.28;

  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _sub;
  SnoreDetector _detector = SnoreDetector(config: _cfg);

  SleepAudioState state = SleepAudioState.idle;
  DateTime? sessionStart;
  String? errorMessage;

  // Live aggregate for the UI.
  SnoreSummary summary = SnoreSummary.from(const []);
  List<SnoreEvent> get events => List.unmodifiable(_detector.events);

  bool get isListening => state == SleepAudioState.listening;

  // ── Window accumulators (carried across PCM chunks) ──────────────────────
  int _winCount = 0;
  double _winTotalSq = 0;
  double _winLowSq = 0;
  double _lpY = 0;
  int _leftoverByte = -1; // odd byte carried to the next chunk

  // ── Lifecycle ────────────────────────────────────────────────────────────

  Future<void> start() async {
    if (state == SleepAudioState.listening) return;
    state = SleepAudioState.requesting;
    errorMessage = null;
    notifyListeners();

    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      state = SleepAudioState.denied;
      notifyListeners();
      return;
    }
    if (!await _recorder.hasPermission()) {
      state = SleepAudioState.denied;
      notifyListeners();
      return;
    }

    try {
      // Start the microphone foreground service BEFORE capture so background
      // (screen-off) access is allowed and the indicator is visible.
      await _channel.invokeMethod('startService');

      final stream = await _recorder.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: _sampleRate,
        numChannels: 1,
        echoCancel: false,
        noiseSuppress: false,
      ));

      _detector = SnoreDetector(config: _cfg);
      _resetWindow();
      sessionStart = DateTime.now();
      state = SleepAudioState.listening;
      summary = SnoreSummary.from(const []);
      notifyListeners();
      _logger.i('SleepAudio: session started (mic FGS up, ${_sampleRate}Hz)');

      _sub = stream.listen(
        _onPcm,
        onError: (Object e) {
          _logger.e('SleepAudio: stream error $e');
          errorMessage = 'Audio error';
          // Don't crash; stop gracefully.
          stop();
        },
        cancelOnError: true,
      );
    } catch (e) {
      _logger.e('SleepAudio: start failed $e');
      state = SleepAudioState.error;
      errorMessage = 'Could not start microphone';
      await _channel.invokeMethod('stopService');
      notifyListeners();
    }
  }

  Future<void> stop() async {
    final wasListening = state == SleepAudioState.listening;
    await _sub?.cancel();
    _sub = null;
    try {
      await _recorder.stop();
    } catch (_) {}
    try {
      await _channel.invokeMethod('stopService');
    } catch (_) {}

    if (wasListening) {
      _detector.finalizeSession();
      summary = SnoreSummary.from(_detector.events);
      final s = sessionStart;
      if (s != null) {
        final session = SnoreSession(
          start: s,
          end: DateTime.now(),
          events: List.of(_detector.events),
        );
        lastSession = session;
        await _store.add(session);
      }
      _logger.i('SleepAudio: session stopped — '
          '${summary.eventCount} events, ${summary.totalMinutes} min');
    }
    state = SleepAudioState.idle;
    notifyListeners();
  }

  Future<void> openSettings() => openAppSettings();

  // ── PCM processing (in-memory only; nothing persisted) ───────────────────

  void _resetWindow() {
    _winCount = 0;
    _winTotalSq = 0;
    _winLowSq = 0;
    _leftoverByte = -1;
  }

  void _onPcm(Uint8List bytes) {
    var i = 0;
    final n = bytes.length;
    // Stitch an odd byte left over from the previous chunk.
    if (_leftoverByte >= 0 && n > 0) {
      final s = _toSample(_leftoverByte, bytes[0]);
      _accumulate(s);
      _leftoverByte = -1;
      i = 1;
    }
    while (i + 1 < n) {
      _accumulate(_toSample(bytes[i], bytes[i + 1]));
      i += 2;
    }
    if (i < n) _leftoverByte = bytes[i]; // carry the odd trailing byte
  }

  double _toSample(int lo, int hi) {
    var v = (hi << 8) | lo;
    if (v >= 0x8000) v -= 0x10000; // sign-extend int16
    return v / 32768.0; // normalize to -1..1
  }

  void _accumulate(double x) {
    _lpY += _lpAlpha * (x - _lpY); // one-pole low-pass (low-band proxy)
    _winTotalSq += x * x;
    _winLowSq += _lpY * _lpY;
    _winCount++;
    if (_winCount >= _windowSamples) _finishWindow();
  }

  void _finishWindow() {
    final total = math.sqrt(_winTotalSq / _winCount);
    final low = math.sqrt(_winLowSq / _winCount);
    final rmsDb = 20 * math.log(math.max(total, 1e-6)) / math.ln10;
    final bandRatio = total > 1e-9 ? (low / total).clamp(0.0, 1.0) : 0.0;

    final before = _detector.events.length;
    _detector.addWindow(rmsDb: rmsDb, bandRatio: bandRatio, time: DateTime.now());
    _resetWindowSums();

    if (_detector.events.length != before) {
      summary = SnoreSummary.from(_detector.events);
      notifyListeners();
      _logger.d('SleepAudio: snore event '
          '(${summary.eventCount} total, ${summary.totalMinutes} min)');
    }
  }

  void _resetWindowSums() {
    _winCount = 0;
    _winTotalSq = 0;
    _winLowSq = 0;
  }

  @override
  void dispose() {
    _sub?.cancel();
    _recorder.dispose();
    super.dispose();
  }
}
