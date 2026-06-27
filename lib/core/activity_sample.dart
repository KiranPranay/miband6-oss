/// Per-minute activity sample fetched from the band's internal storage.
///
/// The Mi Band stores one sample per minute. Each sample has:
///  - category: activity type / sleep stage flag
///  - intensity: movement intensity (0-255)
///  - steps: steps taken in this minute
///  - heartRate: HR reading (0 = not measured)
class ActivitySample {
  final DateTime timestamp;
  final int category;
  final int intensity;
  final int steps;
  final int heartRate;

  // Extended fields for 8-byte samples (Mi Band 6+)
  final int? sleep;
  final int? deepSleep;
  final int? remSleep;

  const ActivitySample({
    required this.timestamp,
    required this.category,
    required this.intensity,
    required this.steps,
    required this.heartRate,
    this.sleep,
    this.deepSleep,
    this.remSleep,
  });

  SleepStage? get sleepStage {
    // An explicit sleep category (4-byte / tagged samples) is authoritative.
    final cat = SleepStage.fromCategory(category);
    if (cat != null) return cat;
    // 8-byte MB6 samples: only the `sleep` byte is a reliable "asleep" signal —
    // a positive value means (light) sleep. The deepSleep/remSleep bytes proved
    // to be a constant marker (always 0x80) rather than real per-sample minutes,
    // so they are deliberately NOT used here — using them classified every
    // awake daytime sample (sleep byte 0) as "deep" sleep. Deep sleep is instead
    // inferred per-session in ActivityStore.computeSleepDays(). A zero sleep byte
    // with no sleep category therefore means awake / not asleep.
    if (sleep != null && sleep! > 0) return SleepStage.light;
    return null;
  }

  bool get isSleep => sleepStage != null;
  bool get isActive => !isSleep && steps > 0;

  Map<String, dynamic> toJson() => {
        't': timestamp.millisecondsSinceEpoch,
        'c': category,
        'i': intensity,
        's': steps,
        'h': heartRate,
        if (sleep != null) 'sl': sleep,
        if (deepSleep != null) 'ds': deepSleep,
        if (remSleep != null) 'rs': remSleep,
      };

  factory ActivitySample.fromJson(Map<String, dynamic> j) => ActivitySample(
        timestamp: DateTime.fromMillisecondsSinceEpoch(j['t'] as int),
        category: j['c'] as int,
        intensity: j['i'] as int,
        steps: j['s'] as int,
        heartRate: j['h'] as int,
        sleep: j['sl'] as int?,
        deepSleep: j['ds'] as int?,
        remSleep: j['rs'] as int?,
      );

  @override
  String toString() =>
      'Sample(${timestamp.toString().substring(11, 16)} cat=$category '
      'int=$intensity steps=$steps hr=$heartRate${sleep != null ? ' s=$sleep ds=$deepSleep rs=$remSleep' : ''})';
}

/// Recognised sleep stages from the band's category byte.
enum SleepStage {
  light,
  deep,
  rem,
  awake,
  nap;

  static SleepStage? fromCategory(int cat) {
    if (cat == 112) return SleepStage.light;
    if (cat == 121) return SleepStage.deep;
    if (cat == 122) return SleepStage.rem;
    if (cat == 126) return SleepStage.awake;
    if (cat == 128) return SleepStage.nap;
    return null;
  }

  String get label {
    switch (this) {
      case SleepStage.light:
        return 'Light';
      case SleepStage.deep:
        return 'Deep';
      case SleepStage.rem:
        return 'REM';
      case SleepStage.awake:
        return 'Awake';
      case SleepStage.nap:
        return 'Nap';
    }
  }
}

class SleepInterval {
  final DateTime startTime;
  final DateTime endTime;
  final SleepStage stage;
  final int durationMinutes;

  SleepInterval({
    required this.startTime,
    required this.endTime,
    required this.stage,
    required this.durationMinutes,
  });
}

class SleepDay {
  final DateTime date;
  final List<SleepInterval> intervals;
  final int totalLightMinutes;
  final int totalDeepMinutes;
  final int totalRemMinutes;
  final int totalAwakeMinutes;
  final int totalNapMinutes;

  SleepDay({
    required this.date,
    required this.intervals,
    required this.totalLightMinutes,
    required this.totalDeepMinutes,
    required this.totalRemMinutes,
    required this.totalAwakeMinutes,
    required this.totalNapMinutes,
  });

  int get totalSleepMinutes =>
      totalLightMinutes + totalDeepMinutes + totalRemMinutes + totalNapMinutes;

  String get durationString {
    final h = totalSleepMinutes ~/ 60;
    final m = totalSleepMinutes % 60;
    return '${h}h ${m}m';
  }

  /// The clock time this session began / ended (from its intervals).
  DateTime? get startTime =>
      intervals.isEmpty ? null : intervals.first.startTime;
  DateTime? get endTime => intervals.isEmpty ? null : intervals.last.endTime;

  /// A short session is treated as a nap rather than a main night's sleep.
  bool get isNap => totalSleepMinutes < 3 * 60;
}

/// SPO2 reading.
class Spo2Reading {
  final DateTime timestamp;
  final int value; // 0-100 percent

  const Spo2Reading({required this.timestamp, required this.value});

  Map<String, dynamic> toJson() => {
        't': timestamp.millisecondsSinceEpoch,
        'v': value,
      };

  factory Spo2Reading.fromJson(Map<String, dynamic> j) => Spo2Reading(
        timestamp: DateTime.fromMillisecondsSinceEpoch(j['t'] as int),
        value: j['v'] as int,
      );
}

/// Hourly step data point.
class HourlySteps {
  final int hour; // 0-23
  final int steps;
  final int calories;

  const HourlySteps({
    required this.hour,
    required this.steps,
    this.calories = 0,
  });
}

/// Heart Rate reading history.
class HeartRateReading {
  final DateTime timestamp;
  final int value;

  const HeartRateReading({required this.timestamp, required this.value});

  Map<String, dynamic> toJson() => {
        't': timestamp.millisecondsSinceEpoch,
        'v': value,
      };

  factory HeartRateReading.fromJson(Map<String, dynamic> j) => HeartRateReading(
        timestamp: DateTime.fromMillisecondsSinceEpoch(j['t'] as int),
        value: j['v'] as int,
      );
}

/// Collapse the band's per-minute step reporting into one value per minute.
///
/// The Mi Band 6 emits several sub-minute activity samples (~every 20s) that all
/// carry the SAME per-minute step count. Naively summing `sample.steps` therefore
/// over-counts daily steps by the sample-per-minute factor (~4–6×) — e.g. a real
/// 4,538-step day summed to ~19,592. The honest per-minute value is the (repeated)
/// count itself, so we take one representative (the max) per minute. Verified on
/// device: collapsing this way reproduces the band's own daily step counter
/// exactly. See docs/reverse-engineering/findings-13.md.
///
/// Returns a map keyed by minute (seconds/millis zeroed) → steps in that minute.
Map<DateTime, int> stepsPerMinute(Iterable<ActivitySample> samples) {
  final perMin = <DateTime, int>{};
  for (final s in samples) {
    final t = s.timestamp;
    final key = DateTime(t.year, t.month, t.day, t.hour, t.minute);
    final cur = perMin[key];
    if (cur == null || s.steps > cur) perMin[key] = s.steps;
  }
  return perMin;
}
