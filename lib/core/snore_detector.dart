import 'dart:math' as math;

/// A detected episode of sound consistent with snoring (NOT a medical
/// diagnosis). Times are wall-clock; intensities are 0..1 loudness above the
/// adaptive room-noise floor.
class SnoreEvent {
  final DateTime start;
  final DateTime end;
  final double peak; // 0..1
  final double mean; // 0..1

  const SnoreEvent({
    required this.start,
    required this.end,
    required this.peak,
    required this.mean,
  });

  int get durationSeconds => end.difference(start).inSeconds;

  Map<String, dynamic> toJson() => {
        's': start.millisecondsSinceEpoch,
        'e': end.millisecondsSinceEpoch,
        'p': peak,
        'm': mean,
      };

  factory SnoreEvent.fromJson(Map<String, dynamic> j) => SnoreEvent(
        start: DateTime.fromMillisecondsSinceEpoch(j['s'] as int),
        end: DateTime.fromMillisecondsSinceEpoch(j['e'] as int),
        peak: (j['p'] as num).toDouble(),
        mean: (j['m'] as num).toDouble(),
      );
}

/// Tunables for snore detection. Defaults are documented in docs/sleep-audio.md.
class SnoreConfig {
  final double windowSeconds; // length of one analysis window
  final int minEventWindows; // sustained windows required for an event
  final int maxGapWindows; // sub-threshold windows tolerated mid-episode
  final double floorMarginDb; // dB above the adaptive floor to count as loud
  final double minBandRatio; // low/mid band-energy ratio gate (snore is low-freq)
  final double floorAdaptRate; // EMA rate for the noise floor (quiet windows)
  final double loudnessSpanDb; // dB above floor mapped to loudness 1.0

  const SnoreConfig({
    this.windowSeconds = 3.0,
    this.minEventWindows = 3,
    this.maxGapWindows = 1,
    this.floorMarginDb = 10.0,
    this.minBandRatio = 0.55,
    this.floorAdaptRate = 0.03,
    this.loudnessSpanDb = 35.0,
  });
}

/// Streaming, adaptive snore detector.
///
/// Fed one analysis window at a time as `(rmsDb, bandRatio)`. It maintains an
/// adaptive room-noise floor (so a quiet and a noisy room both work — no
/// hardcoded dB) and emits a [SnoreEvent] for each run of sustained, elevated,
/// low-frequency windows (duration + amplitude gated, so a one-off clap or a
/// brief voice is not logged). Pure logic — no audio, fully unit-testable.
class SnoreDetector {
  final SnoreConfig config;
  final List<SnoreEvent> events = [];

  double? _floorDb; // adaptive noise floor
  // Current candidate run.
  DateTime? _runStart;
  DateTime? _runLastLoud;
  int _runWindows = 0;
  int _gap = 0;
  double _peak = 0;
  double _sum = 0;
  int _count = 0;

  SnoreDetector({this.config = const SnoreConfig()});

  /// Process one window ending at [time]. [rmsDb] is the window energy in dBFS
  /// (≤ 0); [bandRatio] is low/total band energy (0..1).
  void addWindow({
    required double rmsDb,
    required double bandRatio,
    required DateTime time,
  }) {
    _floorDb ??= rmsDb;
    final floor = _floorDb!;
    final loud = rmsDb > floor + config.floorMarginDb;
    final snoreLike = loud && bandRatio >= config.minBandRatio;

    if (snoreLike) {
      final loudness =
          ((rmsDb - floor) / config.loudnessSpanDb).clamp(0.0, 1.0);
      _runStart ??= time.subtract(
          Duration(milliseconds: (config.windowSeconds * 1000).round()));
      _runLastLoud = time;
      _runWindows++;
      _gap = 0;
      _peak = math.max(_peak, loudness);
      _sum += loudness;
      _count++;
    } else {
      if (_runStart != null) {
        _gap++;
        if (_gap > config.maxGapWindows) {
          _finishRun();
        }
      }
      // Adapt the floor only on clearly-quiet (non-loud) windows so a long
      // snore episode doesn't drag the baseline up.
      if (!loud) {
        _floorDb = floor + (rmsDb - floor) * config.floorAdaptRate;
      }
    }
  }

  /// Close any open run (call at session end).
  void finalizeSession() => _finishRun();

  void _finishRun() {
    if (_runStart != null &&
        _runLastLoud != null &&
        _runWindows >= config.minEventWindows) {
      events.add(SnoreEvent(
        start: _runStart!,
        end: _runLastLoud!,
        peak: _peak,
        mean: _count > 0 ? _sum / _count : 0,
      ));
    }
    _runStart = null;
    _runLastLoud = null;
    _runWindows = 0;
    _gap = 0;
    _peak = 0;
    _sum = 0;
    _count = 0;
  }
}

/// Aggregate stats over a night's snore events.
class SnoreSummary {
  final int totalMinutes;
  final int eventCount;
  final SnoreEvent? loudest;

  const SnoreSummary({
    required this.totalMinutes,
    required this.eventCount,
    required this.loudest,
  });

  factory SnoreSummary.from(List<SnoreEvent> events) {
    if (events.isEmpty) {
      return const SnoreSummary(totalMinutes: 0, eventCount: 0, loudest: null);
    }
    final totalSec =
        events.fold<int>(0, (a, e) => a + e.durationSeconds);
    var loudest = events.first;
    for (final e in events) {
      if (e.peak > loudest.peak) loudest = e;
    }
    return SnoreSummary(
      totalMinutes: (totalSec / 60).round(),
      eventCount: events.length,
      loudest: loudest,
    );
  }
}
