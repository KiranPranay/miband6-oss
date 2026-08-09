import 'activity_sample.dart';

/// Sleep-session detection and staging for Mi Band 6.
///
/// Every rule here was checked against **60 404 real samples spanning 53 days**
/// pulled off the device, not just against the reference implementation. Where
/// the two disagreed, the data won. See `findings-21.md`.
///
/// ## What the band actually tells us
///
/// The per-minute `category` byte splits into two independent halves:
///
/// * **high nibble `0xF` = asleep.** 96.8 % of 04:00 samples carry it, 98.6 % at
///   06:00, ~3-8 % midday. It separates on physiology too: median heart rate
///   65 bpm versus 81, median movement 0 versus 32.
/// * **low nibble = `HuamiConst` kind**, and it is meaningful *independently* of
///   the high nibble. Kind 3 (NONWEAR) and 6 (CHARGING) mean the band recorded
///   nothing: `0xF3` has a valid heart rate in **0.04 %** of 7 654 samples,
///   against 99.6 % for `0xF0`. Counting `0xF3` as sleep is what used to produce
///   14-hour "nights".
///
/// Two things this firmware genuinely cannot give us:
/// * **REM** — byte 7 is identically 0, and the legacy kind table has no REM
///   case. It is never reported, and the hardware gate fails if it ever is.
/// * **Sleep depth from the vendor bytes** — the `deepSleep` byte carries no
///   physiological signal at all. Mean heart rate by `ds` bucket across 16 228
///   sleep samples: 66.1 / 66.6 / 66.6 / 65.9 / 67.1 / 67.6 / 65.9 / 65.2 bpm.
///   Flat. Deep sleep must show a *lower* heart rate; this shows none.
///
/// ## The algorithms, and why these ones
///
/// * **Sleep/wake within a session — Chinoy et al.** (*PLOS ONE* 2020;15(9):
///   e0238464). A weighted activity sum, validated against polysomnography on a
///   **Huami** device's minute-level scalar — the same vendor lineage as this
///   band — at 90.3 % accuracy with a swept-optimal threshold of 10 for that
///   scalar. Both the algorithm and its operating point are published for our
///   class of input. See [_weightedSumAwake].
/// * **Cole–Kripke** (*Sleep* 1992;15(5):461-9) is implemented with its real
///   published coefficients and kept for reference, but is **not** the default:
///   its weights are defined over ActiGraph counts, and converting our intensity
///   byte to those would be an invention. See [coleKripkeAwake].
/// * **Deep sleep — detrended heart-rate dip.** Heart rate falls to its nightly
///   minimum during slow-wave sleep, but it *also* falls towards a circadian
///   nadir near 04:00-05:00 regardless of stage, so an absolute threshold finds
///   the trough rather than the cycles. Subtracting a rolling ±45-minute median
///   (about one sleep cycle) removes that drift; sustained runs below the local
///   baseline are then marked deep. See [_refineWithHeartRate].
///
/// ## Honesty
///
/// Deep/light is an **estimate**. Consumer wearables agree with polysomnography
/// only 50-65 % of the time on multi-state staging, and deep is among the
/// weakest classes. A known unresolved limitation: on our captures the estimated
/// deep sleep is not front-loaded (mean position ~0.55 of the night) when
/// slow-wave sleep should dominate the early cycles. Detrending improved this
/// but did not fix it, and without polysomnography, tuning further would just be
/// fitting to a prior. It is reported in `tool/analyze_capture.dart` rather than
/// hidden.
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

  /// Hard cap on a single session's span.
  ///
  /// 14 h is comfortably above any real night (the 99th percentile of adult
  /// time-in-bed is well under 12 h) while still catching the over-merging that
  /// produced 31-hour "nights" in captured data. Anything longer is a data
  /// artefact, not sleep.
  static const int maxSessionSpanMinutes = 14 * 60;

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

  /// The **high** nibble of the kind byte.
  ///
  /// Gadgetbridge only ever masks the low nibble and treats the high one as
  /// unexplained flags (its `determinePreviousValidActivityType` skips the
  /// values `16, 80, 96, 112` — i.e. `0x10, 0x50, 0x60, 0x70` — with the comment
  /// "all I ever had that are 0 when doing &=0xf"). On this firmware the high
  /// nibble is the informative half. See [sleepFlagNibble].
  static int kindFlags(int category) => (category >> 4) & 0x0F;

  /// The high-nibble value that marks a sample as **asleep** on Mi Band 6.
  ///
  /// Established from 60 404 real samples spanning 53 days (findings-21), not
  /// from the reference implementation:
  ///
  /// | hour | share of samples with high nibble `0xF` |
  /// |---|---|
  /// | 04:00 | 96.8 % |
  /// | 06:00 | 98.6 % |
  /// | 12:00 | 8.2 % |
  /// | 20:00 | 3.3 % |
  ///
  /// and it separates cleanly on physiology, which is the real check:
  ///
  /// | | high nibble `0xF` | everything else |
  /// |---|---|---|
  /// | median heart rate (valid readings) | **65 bpm** | **81 bpm** |
  /// | median movement intensity | 0 | 32 |
  ///
  /// A ~20 % nocturnal heart-rate dip with no movement is exactly what sleep
  /// looks like, so this is the band's own sleep determination and we use it.
  static const int sleepFlagNibble = 0xF;

  /// True when the sample says the band was off the wrist or not measuring.
  ///
  /// The low nibble carries this **independently of the high nibble**, exactly
  /// as `HuamiConst` says (3 = NONWEAR, 6 = CHARGING). The evidence is heart-rate
  /// coverage across 60 404 real samples — a worn band measures a pulse, a
  /// removed one cannot:
  ///
  /// | kind | samples | with a valid heart rate |
  /// |---|---|---|
  /// | `0xF0` | 7 619 | **99.6 %** |
  /// | `0xF9` | 504 | 98.2 % |
  /// | `0x50` | 24 306 | 96.8 % |
  /// | **`0xF3`** | 7 654 | **0.04 %** |
  /// | **`0x73`** | 1 572 | **0.13 %** |
  ///
  /// Low nibble 3 has essentially *no* heart rate at any hour of the day, so it
  /// is not sleep — it is the band recording nothing.
  ///
  /// This matters: counting `0xF3` as sleep is what produced 14-hour "nights"
  /// (e.g. 01:02→15:02 with 98 % efficiency), because a daytime block of 60
  /// not-worn samples per hour chained onto the end of a real night.
  static bool isNotWorn(ActivitySample s) {
    final k = maskedKind(s.category);
    return k == kindNonWear || k == kindCharging;
  }

  /// True when this sample is asleep, according to the band.
  ///
  /// **This replaced a `sleep byte > 0` test that was measurably wrong.**
  /// Against the band's own flag over 53 days of real data, `sleep > 0` marked
  /// **10 831 extra samples** as asleep — concentrated at 20:00-00:00 (evening
  /// stillness on the sofa), 580 of them with a non-zero step count. It
  /// inflated reported sleep by roughly 30 % (median 1 005 vs 774 samples per
  /// day). That is the "sleep numbers are wrong" bug.
  ///
  /// The `sleep` byte is not a boolean at all: during sleep it carries values
  /// 56-62, during the day 0-2, so any `> 0` test was always going to leak.
  static bool _isAsleepSample(ActivitySample s) {
    // Steps in a minute rule it out regardless of any other signal (GB's rule,
    // and it survives contact with the data).
    if (s.steps > 0) return false;
    // A band that is off the wrist is not asleep, however it is flagged.
    if (isNotWorn(s)) return false;
    if (kindFlags(s.category) == sleepFlagNibble) return true;
    // Corroborating legacy codes. These occur only *inside* flagged sleep on
    // this firmware (628 light / 72 deep out of 60 404), so they add little,
    // but they cost nothing and would matter on a firmware that emits them.
    final k = maskedKind(s.category);
    return k == kindLightSleep || k == kindDeepSleep;
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
  /// A block continues while **all three** hold:
  ///  * the gap to the previous asleep sample is ≤ [maxWakeGapMinutes];
  ///  * the sample belongs to the same sleep-day (the 18:00 boundary);
  ///  * the block's span stays under [maxSessionSpanMinutes].
  ///
  /// The last two are the fix for a real defect: with only the gap rule, sleep
  /// flags scattered across a day chained together, and real captured data
  /// produced "nights" of 1 878 and 1 053 minutes — 31 h and 17 h. A night has
  /// to end somewhere, and both a hard cap and the sleep-day boundary are
  /// needed, because a long enough chain of ≤60 min gaps can walk across a full
  /// day without ever tripping the gap rule.
  static List<List<ActivitySample>> _rawBlocks(List<ActivitySample> sorted) {
    final blocks = <List<ActivitySample>>[];
    var current = <ActivitySample>[];
    DateTime? lastAsleep;
    DateTime? blockStart;

    void flush() {
      if (current.isNotEmpty) {
        blocks.add(current);
        current = <ActivitySample>[];
      }
      lastAsleep = null;
      blockStart = null;
    }

    for (final s in sorted) {
      if (!_isAsleepSample(s)) {
        // Wake/nonwear samples never extend a block; whether the block survives
        // is decided by the gap to the next asleep sample below. Measuring the
        // wake time inside the session happens later, in _buildSession.
        continue;
      }

      if (lastAsleep != null) {
        final gap = s.timestamp.difference(lastAsleep!).inMinutes;
        final span = s.timestamp.difference(blockStart!).inMinutes;
        // A long gap ends the session whether it is wakefulness or missing
        // data — we cannot claim someone slept through a period we have no
        // samples for.
        if (gap > maxWakeGapMinutes ||
            span > maxSessionSpanMinutes ||
            sleepDayFor(s.timestamp) != sleepDayFor(lastAsleep!)) {
          flush();
        }
      }
      blockStart ??= s.timestamp;
      current.add(s);
      lastAsleep = s.timestamp;
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
      if (!_isAsleepSample(s) || _weightedSumAwake(intensities, i)) {
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

  /// Cole–Kripke sleep/wake scoring — the **published** coefficients.
  ///
  /// Cole RJ, Kripke DF, Gruen W, Mullaney DJ, Gillin JC. "Automatic sleep/wake
  /// identification from wrist activity." *Sleep* 1992;15(5):461-9. The
  /// validated form scores each minute from a window spanning four minutes
  /// before to two minutes after:
  ///
  /// ```
  /// SI = 0.001 × (106·A₋₄ + 54·A₋₃ + 58·A₋₂ + 76·A₋₁ + 230·A₀ + 74·A₊₁ + 67·A₊₂)
  /// SI < 1  → sleep
  /// SI ≥ 1  → wake
  /// ```
  ///
  /// reported at ~88 % agreement with polysomnography.
  ///
  /// **An earlier version of this file used invented weights**
  /// (0.04/0.20/0.40/0.80/2.00/0.40/0.20, threshold 120), which is not the
  /// published algorithm and had no validation behind it. These are the real
  /// ones.
  ///
  /// ## The calibration caveat, stated plainly
  ///
  /// The coefficients are defined over ActiGraph *activity counts per minute*.
  /// This band reports a 0-255 "intensity" whose scale is undocumented and
  /// certainly not the same. [_intensityToCounts] applies a device scaling
  /// factor derived from our own captures; the *algorithm* is the published one,
  /// the *input scaling* is ours, and no cross-device validation exists for it.
  /// This is why sleep/wake here leans on the band's own flag, with Cole–Kripke
  /// used to find wake episodes **within** a session rather than to define the
  /// session.
  static const List<double> coleKripkeWeights = [
    106, // A₋₄
    54, // A₋₃
    58, // A₋₂
    76, // A₋₁
    230, // A₀
    74, // A₊₁
    67, // A₊₂
  ];

  /// Cole–Kripke's scaling factor P.
  static const double coleKripkeP = 0.001;

  /// Maps the band's 0-255 intensity onto something with the magnitude of
  /// ActiGraph counts/minute.
  ///
  /// **Calibrated, not measured** — and here is exactly how.
  ///
  /// Cole–Kripke scores wake when `SI ≥ 1`. With the published weights that
  /// means an isolated minute needs `counts ≥ 4.35`, and a sustained level needs
  /// `counts ≥ 1.50`. So the scale alone decides the operating point.
  ///
  /// Measured on 16 228 real sleep minutes: 85 % have intensity exactly 0,
  /// p90 = 10, p95 = 26, p99 = 53. Sweeping the scale against that distribution:
  ///
  /// | scale | isolated wake at | sustained wake at | rest minutes scored wake |
  /// |---|---|---|---|
  /// | 8.00 | I ≥ 0.5 | I ≥ 0.2 | ~everything (the first attempt — efficiency collapsed to 48 %) |
  /// | 0.50 | I ≥ 8.7 | I ≥ 3.0 | 12.9 % |
  /// | **0.15** | **I ≥ 29** | **I ≥ 10** | **9.9 %** |
  /// | 0.05 | I ≥ 87 | I ≥ 30 | 3.5 % |
  ///
  /// 0.15 is chosen because it puts the wake fraction of the rest interval at
  /// ~10 %, i.e. a sleep efficiency near the ~85-90 % that healthy adults show —
  /// and because the resulting trigger levels are physiologically sensible: an
  /// isolated minute must reach intensity 29 (around the median of *waking*
  /// movement) to count as wake.
  ///
  /// This is an operating-point calibration against population norms, **not** a
  /// validation. Calibrating properly would need simultaneous polysomnography,
  /// which we do not have. Stated here so nobody mistakes it for one.
  static const double intensityCountScale = 0.15;

  static double _intensityToCounts(int intensity) =>
      intensity * intensityCountScale;

  /// Actiwatch/Philips-Respironics weighted sum — **the primary wake scorer**.
  ///
  /// Chinoy ED, Cuellar JA, Huwa KE, et al. "Performance of seven consumer
  /// sleep-tracking devices compared with polysomnography." / "PSG validation of
  /// minute-to-minute scoring for sleep and wake periods in a consumer wearable
  /// device", *PLOS ONE* 2020;15(9):e0238464.
  ///
  /// ```
  /// TotalActivity = E₀ + 0.2·E₋₁ + 0.2·E₊₁ + 0.04·E₋₂ + 0.04·E₊₂
  /// TotalActivity > threshold → wake
  /// ```
  ///
  /// **Why this and not Cole–Kripke.** Chinoy et al. validated this exact form
  /// against polysomnography on a **Huami** device's minute-level scalar — the
  /// same vendor lineage as this band — and swept the threshold to an optimum of
  /// **10** for that scalar (versus 40 for research-grade Actiwatch counts),
  /// reaching 90.3 % ± 4.3 accuracy and 95.5 % sleep sensitivity on the held-out
  /// set. So both the algorithm *and its operating point* are published for our
  /// class of input, where Cole–Kripke's coefficients are defined over ActiGraph
  /// counts we would have to invent a conversion for.
  ///
  /// On our captures this scores 18.8 % of band-flagged sleep minutes as wake,
  /// i.e. a sleep efficiency near 81 % — in the normal adult range without any
  /// tuning on our part.
  ///
  /// Caveat kept in view: their scalar was a vector magnitude from the vendor
  /// cloud API, ours is the raw intensity byte. Same family, not provably the
  /// same units. Their paper also reports wake **specificity** of only
  /// 55.6 % ± 22.7 — wake detection is unreliable per subject, which is why the
  /// UI presents wake episodes as an estimate.
  static const double chinoyWakeThreshold = 10.0;

  static bool _weightedSumAwake(List<int> intensity, int i) {
    double at(int idx) =>
        (idx < 0 || idx >= intensity.length) ? 0 : intensity[idx].toDouble();
    final total = at(i) +
        0.2 * (at(i - 1) + at(i + 1)) +
        0.04 * (at(i - 2) + at(i + 2));
    return total > chinoyWakeThreshold;
  }

  /// True when Cole–Kripke scores this minute as wake.
  ///
  /// Retained and tested, but **not** the default — see [_weightedSumAwake].
  /// Using it requires [intensityCountScale], a conversion we cannot validate.
  ///
  /// Public only so tests can exercise it. Deliberately no `@visibleForTesting`
  /// annotation: this library is kept free of Flutter imports so that
  /// `tool/analyze_capture.dart` can run it under plain `dart run`, against a
  /// real captured night, with no engine.
  static bool coleKripkeAwake(List<int> intensity, int i) =>
      _coleKripkeAwake(intensity, i);

  static bool _coleKripkeAwake(List<int> intensity, int i) {
    double at(int idx) => (idx < 0 || idx >= intensity.length)
        ? 0
        : _intensityToCounts(intensity[idx]);

    final si = coleKripkeP *
        (coleKripkeWeights[0] * at(i - 4) +
            coleKripkeWeights[1] * at(i - 3) +
            coleKripkeWeights[2] * at(i - 2) +
            coleKripkeWeights[3] * at(i - 1) +
            coleKripkeWeights[4] * at(i) +
            coleKripkeWeights[5] * at(i + 1) +
            coleKripkeWeights[6] * at(i + 2));

    return si >= 1.0;
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

  /// Minimum consecutive minutes below the threshold before deep is claimed.
  ///
  /// Slow-wave episodes run for many minutes; AASM epochs are 30 s and a real
  /// SWS bout spans tens of them. 10 minutes rejects transient dips while
  /// keeping genuine bouts.
  static const int _minDeepRunMinutes = 10;

  /// How far heart rate must sit below its **local** baseline to count as deep.
  ///
  /// Calibrated against 13 real captured nights, not chosen by feel:
  ///
  /// | threshold | median deep share | nights with ~0 % deep |
  /// |---|---|---|
  /// | 1.0 bpm | **16.1 %** | 0/13 |
  /// | 1.25-2.0 bpm | 8.2 % | 1/13 |
  ///
  /// Heart rate is reported as a whole number of bpm and the local baseline is a
  /// median of whole numbers, so the residual is effectively integer-valued —
  /// which is why every threshold from 1.25 to 2.0 collapses onto the same
  /// `residual <= -2` operating point. There are really only two choices here,
  /// and 1.0 bpm is the one that lands inside the 13-23 % healthy adult range.
  ///
  /// As with [intensityCountScale], this is an operating point matched to
  /// population norms, **not** a validation against polysomnography.
  static const double deepDipBpm = 1.0;

  /// Furthest a staged minute may borrow a heart rate from.
  ///
  /// Beyond this the minute is left unstaged rather than filled in. Fabricating
  /// heart rate across a dropout is the most likely way to ship a
  /// plausible-looking lie: interpolated values have almost no variance, and low
  /// variance at a low level is precisely what the deep-sleep rule looks for.
  static const int maxHrGapMinutes = 3;

  /// Half-width of the median filter applied to heart rate before staging.
  ///
  /// Per-minute wrist heart rate is noisy (motion artefact, poor contact); the
  /// staging literature smooths before thresholding. A ±2-minute median is
  /// enough to remove single-sample spikes without blurring a 10-minute bout.
  static const int hrSmoothingHalfWindow = 2;

  /// Marks sustained low-heart-rate runs as deep sleep, and clears deep
  /// elsewhere.
  ///
  /// Replaces two earlier attempts, both discarded on evidence:
  ///  * `deepSleep & 0x7F > 52` — the byte turned out to carry no
  ///    physiological signal at all. Across 16 228 real sleep samples, mean
  ///    heart rate by `ds` bucket was 66.1 / 66.6 / 66.6 / 65.9 / 67.1 / 67.6 /
  ///    65.9 / 65.2 bpm — flat. Deep sleep must show a *lower* heart rate, and
  ///    this shows none.
  ///  * a fixed 6 %-below-median dip — see [deepHrPercentile].
  ///
  /// Honest framing: consumer wearables agree with polysomnography only about
  /// 50-65 % of the time on multi-state staging, and deep/REM are the weakest
  /// classes. This is an estimate and the UI says so.
  static void _refineWithHeartRate(
    List<_Staged> staged,
    List<HeartRateReading> hr,
    double baseline,
  ) {
    if (staged.isEmpty) return;

    // Align one smoothed heart rate to each staged minute.
    final series = _alignedHeartRate(staged, hr);
    if (series.whereType<double>().length < 20) {
      return; // too little heart rate to stage on
    }

    // Detrend against a local baseline before thresholding.
    //
    // Heart rate does not merely dip during slow-wave sleep — it also falls
    // steadily towards a circadian nadir at roughly 04:00-05:00, regardless of
    // stage. Thresholding on the *whole night's* distribution therefore finds
    // the circadian trough rather than the sleep cycles: on 13 captured nights
    // it put the mean deep-sleep position at 0.617 of the night, when
    // slow-wave sleep is known to concentrate in the first cycles.
    //
    // Subtracting a rolling median over about one sleep cycle removes that
    // drift and leaves the cycle-scale dips, which is what SWS actually is.
    final residual = _detrend(series, _deepBaselineHalfWindow);
    if (residual.whereType<double>().length < 20) return;

    // A fixed threshold on the detrended residual, not a percentile of it.
    //
    // A percentile is the wrong tool here: deep sleep is a *minority* of the
    // night by definition (13-23 %), so the 25th percentile of the residuals
    // usually lands in the flat majority and the rule either catches nothing or
    // — on a flat trace — catches everything. A fixed dip is also directly
    // interpretable: "heart rate sustained [deepDipBpm] bpm below its own
    // local baseline", which is the actual physiological claim.
    const threshold = -deepDipBpm;

    var runStart = -1;
    void closeRun(int endExclusive) {
      if (runStart < 0) return;
      if (endExclusive - runStart >= _minDeepRunMinutes) {
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
      // Anything previously called deep reverts to light unless the heart-rate
      // evidence below re-establishes it.
      if (staged[i].stage == SleepStage.deep) {
        staged[i] = _Staged(staged[i].time, SleepStage.light);
      }
      final v = residual[i];
      if (v != null && v <= threshold) {
        if (runStart < 0) runStart = i;
      } else {
        closeRun(i);
      }
    }
    closeRun(staged.length);
  }

  /// Half-width of the rolling baseline used to detrend heart rate.
  ///
  /// A human sleep cycle is about 90 minutes, so a ±45-minute window tracks the
  /// slow circadian fall while leaving cycle-scale dips intact.
  static const int _deepBaselineHalfWindow = 45;

  /// Returns `value − rollingMedian(value)` per minute.
  ///
  /// Null where either the value or the local window is unavailable.
  static List<double?> _detrend(List<double?> series, int halfWindow) {
    return List<double?>.generate(series.length, (i) {
      final v = series[i];
      if (v == null) return null;
      final win = <double>[];
      for (var j = i - halfWindow; j <= i + halfWindow; j++) {
        if (j < 0 || j >= series.length) continue;
        final w = series[j];
        if (w != null) win.add(w);
      }
      if (win.length < 10) return null;
      win.sort();
      return v - win[win.length ~/ 2];
    });
  }

  /// One median-smoothed heart rate per staged minute (null where none is
  /// available within 5 minutes).
  static List<double?> _alignedHeartRate(
      List<_Staged> staged, List<HeartRateReading> hr) {
    // Bucket readings by minute once, instead of scanning all of `hr` per
    // staged minute — this used to be O(staged × hr) and a night is ~500 × 500.
    final byMinute = <int, List<int>>{};
    for (final r in hr) {
      if (!isValidHr(r.value)) continue;
      final key = r.timestamp.millisecondsSinceEpoch ~/ 60000;
      (byMinute[key] ??= []).add(r.value);
    }

    // Reach at most [maxHrGapMinutes] for a substitute reading.
    //
    // This used to reach ±5 minutes, which is nearest-neighbour interpolation
    // by another name: a five-minute PPG dropout became five copies of one
    // value. That is dangerous here specifically, because a repeated value has
    // near-zero local variance — exactly the signature the deep-sleep rule keys
    // on — so a sensor dropout could manufacture a deep-sleep block. A gap
    // longer than the limit yields null and the minute is simply not staged.
    double? rawAt(DateTime t) {
      final base = t.millisecondsSinceEpoch ~/ 60000;
      for (var d = 0; d <= maxHrGapMinutes; d++) {
        for (final k in (d == 0 ? [base] : [base - d, base + d])) {
          final v = byMinute[k];
          if (v != null && v.isNotEmpty) {
            final s = [...v]..sort();
            return s[s.length ~/ 2].toDouble();
          }
        }
      }
      return null;
    }

    final raw = staged.map((s) => rawAt(s.time)).toList();

    // Median filter over ±[hrSmoothingHalfWindow] minutes.
    return List<double?>.generate(raw.length, (i) {
      final win = <double>[];
      for (var j = i - hrSmoothingHalfWindow;
          j <= i + hrSmoothingHalfWindow;
          j++) {
        if (j < 0 || j >= raw.length) continue;
        final v = raw[j];
        if (v != null) win.add(v);
      }
      if (win.isEmpty) return null;
      win.sort();
      return win[win.length ~/ 2];
    });
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
