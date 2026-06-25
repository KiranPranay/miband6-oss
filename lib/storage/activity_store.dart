import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../core/activity_sample.dart';

/// Simple JSON-file persistence for activity samples.
///
/// Stores raw activity samples per day, and provides query methods
/// to compute hourly steps, sleep sessions, and SPO2 readings.
class ActivityStore {
  static const _activityFile = 'activity_data.json';
  static const _spo2File = 'spo2_data.json';
  static const _hrFile = 'hr_data.json';
  static const _lastActivitySyncFile = 'last_activity_sync.txt';
  static const _lastSpo2SyncFile = 'last_spo2_sync.txt';
  static const _lastHrSyncFile = 'last_hr_sync.txt';

  List<ActivitySample> _samples = [];
  List<Spo2Reading> _spo2Readings = [];
  List<HeartRateReading> _hrReadings = [];
  DateTime? _lastActivitySync;
  DateTime? _lastSpo2Sync;
  DateTime? _lastHrSync;

  List<ActivitySample> get samples => _samples;
  List<Spo2Reading> get spo2Readings => _spo2Readings;
  List<HeartRateReading> get hrReadings => _hrReadings;
  DateTime? get lastActivitySync => _lastActivitySync;
  DateTime? get lastSpo2Sync => _lastSpo2Sync;
  DateTime? get lastHrSync => _lastHrSync;
  @Deprecated('Use lastActivitySync')
  DateTime? get lastSyncTimestamp => _lastActivitySync;

  // ── File paths ──────────────────────────────────────────────────────────

  Future<File> _getFile(String name) async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$name');
  }

  // ── Load / Save ─────────────────────────────────────────────────────────

  Future<void> load() async {
    try {
      final f = await _getFile(_activityFile);
      if (await f.exists()) {
        final json = jsonDecode(await f.readAsString()) as List;
        _samples = json
            .map((e) => ActivitySample.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    } catch (_) {}

    try {
      final f = await _getFile(_spo2File);
      if (await f.exists()) {
        final json = jsonDecode(await f.readAsString()) as List;
        _spo2Readings = json
            .map((e) => Spo2Reading.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    } catch (_) {}

    try {
      final f = await _getFile(_hrFile);
      if (await f.exists()) {
        final json = jsonDecode(await f.readAsString()) as List;
        _hrReadings = json
            .map((e) => HeartRateReading.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    } catch (_) {}

    try {
      final f = await _getFile(_lastActivitySyncFile);
      if (await f.exists()) {
        final ms = int.tryParse(await f.readAsString());
        if (ms != null) _lastActivitySync = DateTime.fromMillisecondsSinceEpoch(ms);
      }
    } catch (_) {}

    try {
      final f = await _getFile(_lastSpo2SyncFile);
      if (await f.exists()) {
        final ms = int.tryParse(await f.readAsString());
        if (ms != null) _lastSpo2Sync = DateTime.fromMillisecondsSinceEpoch(ms);
      }
    } catch (_) {}

    try {
      final f = await _getFile(_lastHrSyncFile);
      if (await f.exists()) {
        final ms = int.tryParse(await f.readAsString());
        if (ms != null) _lastHrSync = DateTime.fromMillisecondsSinceEpoch(ms);
      }
    } catch (_) {}
  }

  Future<void> save() async {
    final f1 = await _getFile(_activityFile);
    await f1
        .writeAsString(jsonEncode(_samples.map((s) => s.toJson()).toList()));

    final f2 = await _getFile(_spo2File);
    await f2.writeAsString(
        jsonEncode(_spo2Readings.map((s) => s.toJson()).toList()));

    final f_hr = await _getFile(_hrFile);
    await f_hr.writeAsString(
        jsonEncode(_hrReadings.map((s) => s.toJson()).toList()));

    if (_lastActivitySync != null) {
      final f = await _getFile(_lastActivitySyncFile);
      await f.writeAsString(_lastActivitySync!.millisecondsSinceEpoch.toString());
    }
    if (_lastSpo2Sync != null) {
      final f = await _getFile(_lastSpo2SyncFile);
      await f.writeAsString(_lastSpo2Sync!.millisecondsSinceEpoch.toString());
    }
    if (_lastHrSync != null) {
      final f = await _getFile(_lastHrSyncFile);
      await f.writeAsString(_lastHrSync!.millisecondsSinceEpoch.toString());
    }
  }

  // ── Add data ────────────────────────────────────────────────────────────

  void addSamples(List<ActivitySample> newSamples) {
    // De-duplicate by timestamp
    final existing =
        _samples.map((s) => s.timestamp.millisecondsSinceEpoch).toSet();
    for (final s in newSamples) {
      if (!existing.contains(s.timestamp.millisecondsSinceEpoch)) {
        _samples.add(s);
      }
    }
    _samples.sort((a, b) => a.timestamp.compareTo(b.timestamp));

    if (newSamples.isNotEmpty) {
      _lastActivitySync = DateTime.now();
    }
  }

  void updateActivitySync(DateTime ts) {
    _lastActivitySync = ts;
  }

  void updateSpo2Sync(DateTime ts) {
    _lastSpo2Sync = ts;
  }

  void updateHrSync(DateTime ts) {
    _lastHrSync = ts;
  }

  void addSpo2Readings(List<Spo2Reading> readings) {
    final existing =
        _spo2Readings.map((r) => r.timestamp.millisecondsSinceEpoch).toSet();
    for (final r in readings) {
      if (!existing.contains(r.timestamp.millisecondsSinceEpoch)) {
        _spo2Readings.add(r);
      }
    }
    _spo2Readings.sort((a, b) => a.timestamp.compareTo(b.timestamp));
  }

  void addHeartRateReadings(List<HeartRateReading> readings) {
    final existing =
        _hrReadings.map((r) => r.timestamp.millisecondsSinceEpoch).toSet();
    for (final r in readings) {
      if (!existing.contains(r.timestamp.millisecondsSinceEpoch)) {
        _hrReadings.add(r);
      }
    }
    _hrReadings.sort((a, b) => a.timestamp.compareTo(b.timestamp));
  }

  // ── Queries ─────────────────────────────────────────────────────────────

  /// Get samples for a specific date.
  List<ActivitySample> samplesForDate(DateTime date) {
    return _samples.where((s) {
      return s.timestamp.year == date.year &&
          s.timestamp.month == date.month &&
          s.timestamp.day == date.day;
    }).toList();
  }

  /// Get step count per hour for a given date.
  List<HourlySteps> getStepsByHour(DateTime date) {
    final daySamples = samplesForDate(date);
    final byHour = <int, int>{};
    for (final s in daySamples) {
      final h = s.timestamp.hour;
      byHour[h] = (byHour[h] ?? 0) + s.steps;
    }
    return List.generate(
        24, (h) => HourlySteps(hour: h, steps: byHour[h] ?? 0));
  }

  /// Total steps for a given date.
  int totalStepsForDate(DateTime date) {
    return samplesForDate(date).fold(0, (sum, s) => sum + s.steps);
  }

  // Sleep-session tuning. MB6 sleep data is noisy — samples arrive at an
  // irregular cadence (often sub-minute, sometimes duplicated) — so durations
  // are measured against the wall clock rather than by counting samples.
  static const int _sessionMergeGapMin = 60; // anchors within this = one session
  static const int _minSessionSpanMin = 90; // ignore sessions shorter than this
  static const int _minSessionSleepMin = 60; // …or with less sleep than this
  static const int _maxSessionSleepMin = 12 * 60; // cap over-merged artifacts

  /// Whether a sample looks like the wearer is asleep — used to anchor sessions.
  bool _isAsleepAnchor(ActivitySample s) {
    if (s.sleep != null && s.sleep! > 0) return true;
    final stage = s.sleepStage;
    return stage != null && stage != SleepStage.awake;
  }

  /// Stage of a sample *within a confirmed sleep session*. Here a zero sleep
  /// byte means deep sleep (low movement) rather than awake; explicit REM/nap
  /// categories are honored.
  SleepStage _sessionStage(ActivitySample s) {
    final cat = SleepStage.fromCategory(s.category);
    if (cat == SleepStage.rem) return SleepStage.rem;
    if (cat == SleepStage.nap) return SleepStage.nap;
    if (s.sleep != null && s.sleep! > 0) return SleepStage.light;
    return SleepStage.deep;
  }

  List<SleepDay> computeSleepDays() {
    if (_samples.isEmpty) return [];

    // Sort and de-duplicate identical timestamps (the band re-sends overlapping
    // ranges, and duplicates would otherwise double-count sleep time).
    final sorted = [..._samples]
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final uniq = <ActivitySample>[];
    int? lastMs;
    for (final s in sorted) {
      final ms = s.timestamp.millisecondsSinceEpoch;
      if (ms == lastMs) continue;
      uniq.add(s);
      lastMs = ms;
    }

    // Group asleep anchors into sessions: consecutive anchors no more than
    // [_sessionMergeGapMin] apart belong to the same night.
    final sessions = <List<DateTime>>[];
    DateTime? start, prev;
    for (final s in uniq) {
      if (!_isAsleepAnchor(s)) continue;
      final t = s.timestamp;
      if (start == null) {
        start = t;
        prev = t;
      } else if (t.difference(prev!).inMinutes <= _sessionMergeGapMin) {
        prev = t;
      } else {
        sessions.add([start, prev]);
        start = t;
        prev = t;
      }
    }
    if (start != null) sessions.add([start, prev!]);

    final days = <SleepDay>[];
    for (final ses in sessions) {
      if (ses[1].difference(ses[0]).inMinutes < _minSessionSpanMin) continue;
      final day = _buildSleepDayFromWindow(uniq, ses[0], ses[1]);
      final total = day.totalSleepMinutes;
      // Drop noise (too short) and over-merged artifacts (evening stillness that
      // bridged into the overnight, producing impossibly long > 12 h "nights").
      if (total < _minSessionSleepMin || total > _maxSessionSleepMin) continue;
      days.add(day);
    }
    return days;
  }

  /// Builds a [SleepDay] for the window [start, end]. The total duration is the
  /// session's wall-clock span (sleep onset → wake) — robust to the band's
  /// irregular, sometimes sparse sampling — and that span is apportioned across
  /// stages by the share of samples in each. Contiguous same-stage runs become
  /// hypnogram intervals.
  SleepDay _buildSleepDayFromWindow(
      List<ActivitySample> all, DateTime start, DateTime end) {
    final win = all
        .where(
            (s) => !s.timestamp.isBefore(start) && !s.timestamp.isAfter(end))
        .toList();

    final spanMin = end.difference(start).inMinutes;
    final date = DateTime(end.year, end.month, end.day);
    if (win.isEmpty || spanMin <= 0) {
      return SleepDay(
        date: date,
        intervals: const [],
        totalLightMinutes: 0,
        totalDeepMinutes: 0,
        totalRemMinutes: 0,
        totalAwakeMinutes: 0,
        totalNapMinutes: 0,
      );
    }

    // Apportion the span across stages by each stage's share of the samples.
    int cLight = 0, cDeep = 0, cRem = 0, cAwake = 0, cNap = 0;
    for (final s in win) {
      switch (_sessionStage(s)) {
        case SleepStage.light:
          cLight++;
          break;
        case SleepStage.deep:
          cDeep++;
          break;
        case SleepStage.rem:
          cRem++;
          break;
        case SleepStage.awake:
          cAwake++;
          break;
        case SleepStage.nap:
          cNap++;
          break;
      }
    }
    final n = win.length;
    int alloc(int c) => (spanMin * c / n).round();

    // Hypnogram intervals from contiguous same-stage runs (real timestamps).
    final intervals = <SleepInterval>[];
    SleepStage? runStage;
    DateTime? runStart;
    for (final s in win) {
      final st = _sessionStage(s);
      if (runStage != st) {
        if (runStage != null && runStart != null) {
          final d = s.timestamp.difference(runStart).inMinutes;
          intervals.add(SleepInterval(
            startTime: runStart,
            endTime: s.timestamp,
            stage: runStage,
            durationMinutes: d > 0 ? d : 1,
          ));
        }
        runStage = st;
        runStart = s.timestamp;
      }
    }
    if (runStage != null && runStart != null) {
      final d = end.difference(runStart).inMinutes;
      intervals.add(SleepInterval(
        startTime: runStart,
        endTime: end,
        stage: runStage,
        durationMinutes: d > 0 ? d : 1,
      ));
    }

    return SleepDay(
      date: date,
      intervals: intervals,
      totalLightMinutes: alloc(cLight),
      totalDeepMinutes: alloc(cDeep),
      totalRemMinutes: alloc(cRem),
      totalAwakeMinutes: alloc(cAwake),
      totalNapMinutes: alloc(cNap),
    );
  }

  /// Get the computed sleep day record for a specific date.
  SleepDay? getSleepForDate(DateTime date) {
    final days = computeSleepDays();
    try {
      return days.firstWhere((d) => 
        d.date.year == date.year && 
        d.date.month == date.month && 
        d.date.day == date.day);
    } catch (_) {
      return null;
    }
  }

  /// Get SPO2 readings for a specific date.
  List<Spo2Reading> getSpo2ForDate(DateTime date) {
    return _spo2Readings.where((r) {
      return r.timestamp.year == date.year &&
          r.timestamp.month == date.month &&
          r.timestamp.day == date.day;
    }).toList();
  }

  /// Purge data older than N days to keep storage bounded.
  void purgeOlderThan(int days) {
    final cutoff = DateTime.now().subtract(Duration(days: days));
    _samples.removeWhere((s) => s.timestamp.isBefore(cutoff));
    _spo2Readings.removeWhere((r) => r.timestamp.isBefore(cutoff));
  }
}
