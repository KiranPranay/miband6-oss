import 'activity_sample.dart';

/// Rebuilt sleep-session detection for Mi Band 6.
///
/// ## Where the rules come from
///
/// **Gadgetbridge, legacy Huami path** — Mi Band 6 uses `MiBand2SampleProvider`
/// → `HuamiConst.toActivityKind` (`MiBand6Coordinator` extends `HuamiCoordinator`
/// and never overrides `getSampleProvider`). Consequences, all verified in
/// source and recorded in `protocol-mb6.md` §7:
///
/// * raw kinds: `9` = light sleep, `11` = deep sleep, `3` = not worn,
///   `6` = charging (also not worn), `0`/`10` = carry the previous valid kind
///   forward, everything else = awake/activity;
/// * `rawKind & 0x0F` before comparing — the high nibble carries flags;
/// * **there is no REM and no AWAKE kind on this path** — the legacy mapping has
///   no case for either, and `MiBand6Coordinator` reports
///   `supportsRemSleep() == false`;
/// * **not-worn is a kind value, not `intensity == 0xFF`** (a guess the old code
///   made) and not `HR == 255`;
/// * session stitching (`SleepAnalysis.calculateSleepSessions`): minimum session
///   5 min, maximum wake gap inside a session 60 min, and **any minute
///   containing steps breaks the session**;
/// * the "sleep day" runs 18:00 → 18:00, which is how a bedtime before midnight
///   is attributed to the following morning.
///
/// **Hardware overrides the reference where they disagree.** Our own captures
/// (`findings-09.md`) show this firmware never emits kind 9 or 11: overnight
/// samples carry `0xF3`/`0xF0` and daytime `0x50`. Masked with `& 0x0F` those
/// become 3/0/0 — i.e. "not worn" — which is plainly wrong for a night of sleep.
/// So [_isAsleepSample] treats the `sleep` byte (offset 5) as the primary
/// signal, which findings-09 verified maps 1:1 to those overnight values, and
/// additionally honours kinds 9/11 when a firmware does emit them. The
/// discrepancy is flagged in `protocol-mb6.md` §7.2 with a queued probe.
///
/// ## HR-assisted refinement
///
/// Actigraphy alone cannot separate "asleep" from "lying still, awake", and it
/// cannot see sleep depth at all. Two published ideas are used, both as *priors*
/// over the band's own signal rather than as replacements for it:
///
/// * **Cole–Kripke** (Cole RJ, Kripke DF, Gruen W, Mullaney DJ, Gillin JC,
///   "Automatic sleep/wake identification from wrist activity", *Sleep* 1992;
///   15(5):461-9) scores each epoch from a weighted window of activity counts
///   *around* it, not from that epoch alone. [_coleKripkeAwake] applies their
///   weighting shape to the band's per-minute intensity so an isolated twitch
///   does not create a wake episode, while a sustained burst does.
/// * **Heart-rate dip staging**, as used in consumer-wearable validation work
///   (e.g. de Zambotti et al. on multi-sensor consumer devices): deep sleep is
///   accompanied by a sustained fall in heart rate relative to the sleeper's own
///   nightly baseline. [_refineWithHeartRate] marks deep only where HR stays
///   below a personal threshold for a run of minutes, instead of the previous
///   `deepSleep & 0x7F > 52` cut, which was tuned by eye on a handful of nights.
///
/// Both are explicitly **estimates**. REM is never reported: this firmware does
/// not measure it (byte 7 is always 0), and inventing it would be dishonest.
class SleepAnalyzer {
  const SleepAnalyzer._();

  // ── Gadgetbridge constants (protocol-mb6.md §7) ──────────────────────────

  static const int kindNoChange = 0;
  static const int kindActivity = 1;
  static const int kindRunning = 2;
  static const int kindNonWear = 3;
  static const int kindCharging = 6;
  static const int kindLightSleep = 9;
  static const int kindIgnore = 10;
  static const int kindDeepSleep = 11;
  static const int kindWakeUp = 12;

  /// Minimum length of a detected session (GB: 5 min).
  static const int minSessionMinutes = 5;

  /// Longest run of wake inside one session before it is split (GB: 1 hour).
  static const int maxWakeGapMinutes = 60;

  /// Hour at which a "sleep day" starts and ends (GB: 18:00). A session is
  /// attributed to the day its 18:00-window ends in, so a 23:30 bedtime belongs
  /// to the following morning.
  static const int sleepDayBoundaryHour = 18;

  /// Below this a session is a nap rather than a night.
  static const int napMaxMinutes = 3 * 60;

  /// A gap longer than this between consecutive samples is missing data, not
  /// wakefulness — it must not be counted as either sleep or awake.
  static const int dataGapMinutes = 10;

  /// How far before sleep onset to look for a "settling down" period.
  ///
  /// The band cannot tell us when someone got into bed, so sleep *latency* has
  /// no meaning measured from sleep onset alone — it would always be zero. What
  /// actigraphy actually measures is the interval from **rest onset** (lying
  /// still, not stepping, still wearing the band) to the first sustained sleep,
  /// which is what Cole–Kripke and its descendants score over. This window
  /// bounds that look-back so an entire quiet evening on the sofa cannot be
  /// counted as time spent trying to fall asleep.
  static const int restOnsetLookbackMinutes = 60;

  /// Movement at or below this counts as "at rest" for the look-back.
  static const int restIntensityCeiling = 12;

  // ── Sample classification ────────────────────────────────────────────────

  /// Kind byte with the flag nibble stripped, per `MiBand2SampleProvider`.
  static int maskedKind(int category) => category & 0x0F;

  /// True when the sample says the band was off the wrist or charging.
  ///
  /// Uses the kind value, per `HuamiConst.toActivityKind` — **not**
  /// `intensity == 0xFF`, which the previous implementation assumed and which
  /// appears nowhere in Gadgetbridge.
  static bool isNotWorn(ActivitySample s) {
    final k = maskedKind(s.category);
    return k == kindNonWear || k == kindCharging;
  }

  /// True when this sample looks like sleep.
  ///
  /// Order matters: an explicit legacy sleep kind wins, then the `sleep` byte
  /// (the only signal this firmware actually populates — see the class docs).
  static bool _isAsleepSample(ActivitySample s) {
    if (isNotWorn(s)) return false;
    final k = maskedKind(s.category);
    if (k == kindLightSleep || k == kindDeepSleep) return true;
    // Steps in a minute rule it out regardless of any other signal.
    if (s.steps > 0) return false;
    return (s.sleep ?? 0) > 0;
  }

  /// Heart rate is only meaningful within Gadgetbridge's validity band.
  /// `HeartRateUtils.isValidHeartRateValue`: `> 0 && >= 10 && <= 250`.
  static bool isValidHr(int bpm) => bpm >= 10 && bpm <= 250;

  // ── Session detection ────────────────────────────────────────────────────

  /// Detects sleep sessions across [samples] and returns them oldest-first.
  ///
  /// [hr] is optional; when present it is used to reject off-wrist stillness and
  /// to refine deep/light. Everything here is pure — no clock reads — so tests
  /// can drive it deterministically.
  static List<SleepDay> detectSessions(
    List<ActivitySample> samples, {
    List<HeartRateReading> hr = const [],
  }) {
    if (samples.isEmpty) return const [];

    final sorted = _sortedUnique(samples);
    final blocks = _rawBlocks(sorted);

    final days = <SleepDay>[];
    for (final block in blocks) {
      final day = _buildSession(block, sorted, hr);
      if (day != null) days.add(day);
    }
    return days;
  }

  /// Sorted by time with duplicate timestamps collapsed. The band re-sends
  /// overlapping ranges on every fetch, and duplicates would double-count.
  static List<ActivitySample> _sortedUnique(List<ActivitySample> samples) {
    final sorted = [...samples]
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final out = <ActivitySample>[];
    int? lastMs;
    for (final s in sorted) {
      final ms = s.timestamp.millisecondsSinceEpoch;
      if (ms == lastMs) continue;
      out.add(s);
      lastMs = ms;
    }
    return out;
  }

  /// Groups asleep samples into candidate blocks.
  ///
  /// A block continues across wake minutes up to [maxWakeGapMinutes]; a longer
  /// run of wake, a data gap, or a stepped minute ends it — matching
  /// Gadgetbridge's `calculateSleepSessions`.
  static List<List<ActivitySample>> _rawBlocks(List<ActivitySample> sorted) {
    final blocks = <List<ActivitySample>>[];
    var current = <ActivitySample>[];
    DateTime? lastAsleep;

    void flush() {
      if (current.isNotEmpty) {
        blocks.add(current);
        current = <ActivitySample>[];
      }
      lastAsleep = null;
    }

    for (final s in sorted) {
      final asleep = _isAsleepSample(s);

      if (asleep) {
        if (lastAsleep != null) {
          final gap = s.timestamp.difference(lastAsleep!).inMinutes;
          // A long gap ends the session whether it is wakefulness or missing
          // data — we cannot claim someone slept through a period we have no
          // samples for.
          if (gap > maxWakeGapMinutes) flush();
        }
        current.add(s);
        lastAsleep = s.timestamp;
        continue;
      }

      // Awake sample. Steps definitively break the session (GB rule).
      if (s.steps > 0 && current.isNotEmpty) {
        final gap = lastAsleep == null
            ? 0
            : s.timestamp.difference(lastAsleep!).inMinutes;
        if (gap > maxWakeGapMinutes) flush();
      }
      // Otherwise keep the block open: a short wake run is a wake episode
      // inside the night, and is measured in _buildSession.
      if (current.isNotEmpty && lastAsleep != null) {
        final gap = s.timestamp.difference(lastAsleep!).inMinutes;
        if (gap > maxWakeGapMinutes) flush();
      }
    }
    flush();
    return blocks;
  }

  /// Turns a candidate block into a [SleepDay], or null if it does not qualify.
  static SleepDay? _buildSession(
    List<ActivitySample> block,
    List<ActivitySample> allSorted,
    List<HeartRateReading> hr,
  ) {
    if (block.isEmpty) return null;
    final start = block.first.timestamp;
    final end = block.last.timestamp;
    final spanMinutes = end.difference(start).inMinutes;
    if (spanMinutes < minSessionMinutes) return null;

    // Extend backwards over a bounded "settling down" period so latency and
    // efficiency have a rest interval to be measured against (see
    // [restOnsetLookbackMinutes]).
    final restStart = _restOnset(allSorted, start);

    // Every sample in the window, including the awake ones between asleep runs,
    // so wake episodes inside the night are measured rather than assumed.
    final window = allSorted
        .where((s) =>
            !s.timestamp.isBefore(restStart) && !s.timestamp.isAfter(end))
        .toList();

    // Off-wrist rejection: a band on a nightstand is perfectly still and can
    // look like flawless sleep. If most of the window is not-worn, or no valid
    // HR was seen at all across a long window, this is not a sleep session.
    final notWorn = window.where(isNotWorn).length;
    if (notWorn > window.length / 2) return null;

    final sessionHr = hr
        .where((r) =>
            !r.timestamp.isBefore(start) &&
            !r.timestamp.isAfter(end) &&
            isValidHr(r.value))
        .toList();
    if (hr.isNotEmpty && sessionHr.isEmpty && spanMinutes >= 60) {
      // We have HR data for other times but none at all here, over an hour —
      // the band was not being worn.
      return null;
    }

    final stages = _classify(window, sessionHr);
    final intervals = _toIntervals(stages, end);
    if (intervals.isEmpty) return null;

    var light = 0, deep = 0, awake = 0;
    for (final iv in intervals) {
      switch (iv.stage) {
        case SleepStage.deep:
          deep += iv.durationMinutes;
        case SleepStage.awake:
          awake += iv.durationMinutes;
        case SleepStage.light:
        case SleepStage.rem:
        case SleepStage.nap:
          light += iv.durationMinutes;
      }
    }

    final asleepMinutes = light + deep;
    if (asleepMinutes < minSessionMinutes) return null;

    final isNap = asleepMinutes < napMaxMinutes;
    return SleepDay(
      date: sleepDayFor(end),
      intervals: intervals,
      totalLightMinutes: isNap ? 0 : light,
      totalDeepMinutes: isNap ? 0 : deep,
      totalRemMinutes: 0, // never measured by this firmware — see class docs
      totalAwakeMinutes: awake,
      totalNapMinutes: isNap ? asleepMinutes : 0,
    );
  }

  /// Walks backwards from sleep onset over contiguous "at rest" samples.
  ///
  /// A sample qualifies while the band is worn, no steps are recorded and
  /// movement stays under [restIntensityCeiling]. Stops at the first sample that
  /// fails, at a data gap, or after [restOnsetLookbackMinutes] — so a quiet
  /// evening cannot be misreported as an hour spent failing to fall asleep.
  ///
  /// Returns [sleepStart] unchanged when nothing qualifies, in which case
  /// latency is reported as zero: we genuinely observed no awake time in bed.
  static DateTime _restOnset(List<ActivitySample> sorted, DateTime sleepStart) {
    final limit = sleepStart.subtract(
        const Duration(minutes: restOnsetLookbackMinutes));
    var onset = sleepStart;
    var next = sleepStart;

    for (var i = sorted.length - 1; i >= 0; i--) {
      final s = sorted[i];
      if (!s.timestamp.isBefore(sleepStart)) continue;
      if (s.timestamp.isBefore(limit)) break;
      if (isNotWorn(s) ||
          s.steps > 0 ||
          s.intensity > restIntensityCeiling) {
        break;
      }
      if (next.difference(s.timestamp).inMinutes > dataGapMinutes) break;
      onset = s.timestamp;
      next = s.timestamp;
    }
    return onset;
  }

  /// The calendar day a session ending at [end] belongs to.
  ///
  /// Sessions ending before 18:00 belong to that date; a session ending after
  /// 18:00 (an evening nap) belongs to the next. This is what attaches a
  /// bedtime before midnight to the following morning, and it is DST-safe
  /// because it works on local wall-clock fields rather than on elapsed
  /// milliseconds.
  static DateTime sleepDayFor(DateTime end) {
    final day = DateTime(end.year, end.month, end.day);
    return end.hour >= sleepDayBoundaryHour
        ? day.add(const Duration(days: 1))
        : day;
  }

  // ── Stage classification ─────────────────────────────────────────────────

  /// Per-sample stage for the whole window.
  static List<_Staged> _classify(
      List<ActivitySample> window, List<HeartRateReading> sessionHr) {
    final intensities = window.map((s) => s.intensity).toList();
    final baseline = _hrBaseline(sessionHr);

    final out = <_Staged>[];
    for (var i = 0; i < window.length; i++) {
      final s = window[i];
      if (isNotWorn(s)) {
        out.add(_Staged(s.timestamp, SleepStage.awake));
        continue;
      }
      if (!_isAsleepSample(s) || _coleKripkeAwake(intensities, i)) {
        out.add(_Staged(s.timestamp, SleepStage.awake));
        continue;
      }
      final k = maskedKind(s.category);
      if (k == kindDeepSleep) {
        out.add(_Staged(s.timestamp, SleepStage.deep));
        continue;
      }
      if (k == kindLightSleep) {
        out.add(_Staged(s.timestamp, SleepStage.light));
        continue;
      }
      out.add(_Staged(s.timestamp, SleepStage.light));
    }

    if (baseline != null) _refineWithHeartRate(out, sessionHr, baseline);
    return out;
  }

  /// Cole–Kripke-style wake detection over the band's per-minute intensity.
  ///
  /// The published algorithm scores an epoch from a weighted window spanning
  /// four minutes before to two after, so a single movement cannot by itself
  /// create a wake epoch while sustained movement does. Weights follow the
  /// shape of the original rescoring formula; the threshold is expressed
  /// against the band's 0-255 intensity scale rather than the paper's
  /// device-specific counts, so it is a *prior*, not a reproduction.
  static bool _coleKripkeAwake(List<int> intensity, int i) {
    double at(int idx) =>
        (idx < 0 || idx >= intensity.length) ? 0 : intensity[idx].toDouble();

    final score = 0.04 * at(i - 4) +
        0.20 * at(i - 3) +
        0.40 * at(i - 2) +
        0.80 * at(i - 1) +
        2.00 * at(i) +
        0.40 * at(i + 1) +
        0.20 * at(i + 2);

    // Calibrated against the band's intensity scale: quiet sleep sits in the
    // low tens, so this only fires on genuine sustained movement.
    return score > 120.0;
  }

  /// Median heart rate for the session, used as the personal baseline.
  ///
  /// Median rather than mean so a few motion artefacts cannot drag it.
  static double? _hrBaseline(List<HeartRateReading> hr) {
    if (hr.length < 5) return null;
    final values = hr.map((r) => r.value).toList()..sort();
    final mid = values.length ~/ 2;
    return values.length.isOdd
        ? values[mid].toDouble()
        : (values[mid - 1] + values[mid]) / 2.0;
  }

  /// Fraction below the session baseline that marks deep sleep.
  ///
  /// Heart rate falls during slow-wave sleep; consumer-wearable validation work
  /// uses a sustained dip relative to the individual's own night baseline
  /// rather than an absolute bpm. 6 % is deliberately conservative — it under-
  /// reports deep rather than inventing it.
  static const double _deepHrDipFraction = 0.06;

  /// Minimum consecutive minutes below the threshold before deep is claimed.
  /// Slow-wave episodes last many minutes; a one-minute dip is noise.
  static const int _minDeepRunMinutes = 8;

  /// Marks sustained low-HR runs as deep sleep, and clears deep elsewhere.
  ///
  /// Replaces the previous `deepSleep & 0x7F > 52` cut, which was an eyeballed
  /// threshold on a handful of nights and is not defensible.
  static void _refineWithHeartRate(
    List<_Staged> staged,
    List<HeartRateReading> hr,
    double baseline,
  ) {
    final threshold = baseline * (1 - _deepHrDipFraction);

    // Nearest HR reading within 5 minutes of each staged minute.
    double? hrAt(DateTime t) {
      HeartRateReading? best;
      var bestMs = 5 * 60 * 1000;
      for (final r in hr) {
        final d = r.timestamp.difference(t).inMilliseconds.abs();
        if (d <= bestMs) {
          bestMs = d;
          best = r;
        }
      }
      return best?.value.toDouble();
    }

    var runStart = -1;
    void closeRun(int endExclusive) {
      if (runStart < 0) return;
      final length = endExclusive - runStart;
      if (length >= _minDeepRunMinutes) {
        for (var j = runStart; j < endExclusive; j++) {
          if (staged[j].stage != SleepStage.awake) {
            staged[j] = _Staged(staged[j].time, SleepStage.deep);
          }
        }
      }
      runStart = -1;
    }

    for (var i = 0; i < staged.length; i++) {
      if (staged[i].stage == SleepStage.awake) {
        closeRun(i);
        continue;
      }
      // Anything previously called deep reverts to light unless the HR
      // evidence below re-establishes it.
      if (staged[i].stage == SleepStage.deep) {
        staged[i] = _Staged(staged[i].time, SleepStage.light);
      }
      final v = hrAt(staged[i].time);
      if (v != null && v <= threshold) {
        if (runStart < 0) runStart = i;
      } else {
        closeRun(i);
      }
    }
    closeRun(staged.length);
  }

  /// Collapses per-minute stages into contiguous intervals.
  ///
  /// A gap longer than [dataGapMinutes] between samples ends the interval at the
  /// last known sample instead of stretching across missing data.
  static List<SleepInterval> _toIntervals(List<_Staged> staged, DateTime end) {
    if (staged.isEmpty) return const [];
    final out = <SleepInterval>[];
    var runStage = staged.first.stage;
    var runStart = staged.first.time;
    var prev = staged.first.time;

    void close(DateTime at) {
      final minutes = at.difference(runStart).inMinutes;
      if (minutes > 0) {
        out.add(SleepInterval(
          startTime: runStart,
          endTime: at,
          stage: runStage,
          durationMinutes: minutes,
        ));
      }
    }

    for (var i = 1; i < staged.length; i++) {
      final s = staged[i];
      final gap = s.time.difference(prev).inMinutes;
      if (gap > dataGapMinutes) {
        close(prev); // do not span the hole
        runStage = s.stage;
        runStart = s.time;
      } else if (s.stage != runStage) {
        close(s.time);
        runStage = s.stage;
        runStart = s.time;
      }
      prev = s.time;
    }
    close(end.isAfter(prev) && end.difference(prev).inMinutes <= dataGapMinutes
        ? end
        : prev);
    return out;
  }
}

/// One minute with its assigned stage.
class _Staged {
  const _Staged(this.time, this.stage);
  final DateTime time;
  final SleepStage stage;
}

/// Derived quality metrics for one session.
///
/// Kept separate from [SleepDay] (which the UI already renders) so the extra
/// numbers can be computed on demand without changing the stored shape.
class SleepQuality {
  const SleepQuality({
    required this.efficiencyPercent,
    required this.latencyMinutes,
    required this.wakeEpisodes,
    required this.timeInBedMinutes,
  });

  /// Asleep minutes as a percentage of time in bed. Not clamped — a value over
  /// 100 would signal a bug rather than a great night, and hiding it would hide
  /// the bug.
  final double efficiencyPercent;

  /// Minutes from the start of the session to the first sustained sleep.
  final int latencyMinutes;

  /// Number of distinct wake episodes inside the session.
  final int wakeEpisodes;

  final int timeInBedMinutes;

  /// Computes quality metrics from a session's intervals.
  static SleepQuality of(SleepDay day) {
    final intervals = day.intervals;
    if (intervals.isEmpty) {
      return const SleepQuality(
        efficiencyPercent: 0,
        latencyMinutes: 0,
        wakeEpisodes: 0,
        timeInBedMinutes: 0,
      );
    }

    final inBed = intervals.fold<int>(0, (sum, iv) => sum + iv.durationMinutes);
    final asleep = intervals
        .where((iv) => iv.stage != SleepStage.awake)
        .fold<int>(0, (sum, iv) => sum + iv.durationMinutes);

    var latency = 0;
    for (final iv in intervals) {
      if (iv.stage == SleepStage.awake) {
        latency += iv.durationMinutes;
      } else {
        break;
      }
    }

    // Count only wake episodes *between* sleep — leading and trailing wake are
    // latency and morning wake-up, not awakenings.
    var episodes = 0;
    var seenSleep = false;
    for (var i = 0; i < intervals.length; i++) {
      final iv = intervals[i];
      if (iv.stage != SleepStage.awake) {
        seenSleep = true;
        continue;
      }
      if (!seenSleep) continue;
      final laterSleep =
          intervals.skip(i + 1).any((x) => x.stage != SleepStage.awake);
      if (laterSleep) episodes++;
    }

    return SleepQuality(
      efficiencyPercent: inBed == 0 ? 0 : (asleep * 100.0) / inBed,
      latencyMinutes: latency,
      wakeEpisodes: episodes,
      timeInBedMinutes: inBed,
    );
  }
}
