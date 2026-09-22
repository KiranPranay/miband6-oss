import 'dart:math' as math;

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
/// * **Deep sleep — estimated, two-process model.** Heart rate dips during
///   slow-wave sleep, but it also drifts down all night towards a circadian
///   nadir, and a detector that compares each minute to its own neighbourhood
///   finds dips everywhere (findings-24). The current rule subtracts a *slow*
///   trend (±2 h) to remove the drift, then requires the residual dip to be
///   deeper the later it is in the night — because slow-wave propensity
///   (Borbély's Process S) decays from sleep onset. Front-loading is therefore
///   a property of the model, not a coincidence of the data. See
///   [_refineWithHeartRate] and findings-25.
///
/// ## Honesty
///
/// What this class can *validate* is **asleep versus awake**, which is what
/// Chinoy checked on this vendor's hardware. Deep is an **estimate** and every
/// surface that shows it says so. Consumer wearables agree with
/// polysomnography only 50-65 % of the time on multi-state staging, and deep
/// is among the weakest classes; this app does not claim to beat that. The
/// harness checks the estimate is at least *shaped* like slow-wave sleep —
/// front-loaded, and a minority of the night.
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


  /// A minute that can anchor a sleep block: the band's own flag, **or**
  /// Chinoy's actigraphy scorer saying "asleep" on a worn, step-free minute.
  ///
  /// The flag alone was not enough. On 2026-09-20 the band was worn all night
  /// (0 % not-worn, 97 % heart-rate coverage) and flagged only 20 % of the
  /// overnight minutes; on 09-22, 11 %. Both nights were reported as **no
  /// sleep at all**, and the Sleep screen fell back to a 21-minute nap. The
  /// flag is the band's determination and a strong signal when present, but
  /// its absence is not evidence of wakefulness.
  ///
  /// Chinoy et al. validated the weighted-activity scorer at 90.3 % against
  /// polysomnography on this vendor's minute-level intensity, so a run of
  /// still, worn, step-free minutes is a legitimate anchor — *provided* the
  /// session it produces is corroborated by heart rate (see the gate in
  /// `_buildSession`). Without that gate this is exactly how findings-21's
  /// 14-hour "nights" were made.
  static bool _isAsleepSample(
    ActivitySample s,
    List<int> intensities,
    int i, {
    Map<int, int> hrByMinute = const {},
    double? wakingHr,
  }) {
    if (s.steps > 0) return false;
    if (isNotWorn(s)) return false;
    if (kindFlags(s.category) == sleepFlagNibble) return true;
    if (!kAnchorOnActigraphy) return false;
    // Corroborate *this minute*: the pulse has to be down. A session-level
    // median was tried first and let an evening on the sofa stitch onto the
    // night — 10 "nights" over 12 h, one of 833 min, because the whole
    // block's median was dragged down by the real sleep in it. Per-minute, a
    // minute at waking heart rate is simply awake, however still.
    if (wakingHr == null) return false;
    final bpm = hrByMinute[s.timestamp.millisecondsSinceEpoch ~/ 60000];
    if (bpm == null || bpm > wakingHr * (1 - restingDipFraction)) return false;
    // Still-ness is Chinoy's, and only Chinoy's. A looser movement ceiling
    // (intensity ≤ 80 with the pulse down) was tried to recover a restless
    // night the band did not flag; it also recovered two *daytime* sessions
    // at a desk, six nights over 12 h and undid the deep-sleep front-loading —
    // this wearer's seated pulse sits under the gate often enough. See
    // findings-26. A night that is neither flagged nor still is reported as
    // what it is, via [restOnlyNight], not as sleep.
    return !_weightedSumAwake(intensities, i);
  }

  /// Median valid heart rate per minute, for the per-minute anchor check.
  static Map<int, int> _hrByMinute(List<HeartRateReading> hr) {
    final buckets = <int, List<int>>{};
    for (final r in hr) {
      if (!isValidHr(r.value)) continue;
      (buckets[r.timestamp.millisecondsSinceEpoch ~/ 60000] ??= []).add(r.value);
    }
    return {
      for (final e in buckets.entries)
        e.key: (e.value..sort())[e.value.length ~/ 2],
    };
  }

  /// Minutes of consecutive anchors needed before a block may open.
  static const int minOnsetRunMinutes = 10;

  /// True when [i] begins a run of at least [minOnsetRunMinutes] consecutive
  /// anchored minutes (consecutive in time — a gap in the samples breaks it).
  static bool _sustainedFrom(
    List<ActivitySample> sorted,
    List<int> intensities,
    int i, {
    required Map<int, int> hrByMinute,
    required double? wakingHr,
  }) {
    var count = 0;
    for (var j = i; j < sorted.length && count < minOnsetRunMinutes; j++) {
      if (j > i &&
          sorted[j].timestamp.difference(sorted[j - 1].timestamp).inMinutes > 1) {
        return false;
      }
      if (!_isAsleepSample(sorted[j], intensities, j,
          hrByMinute: hrByMinute, wakingHr: wakingHr)) {
        return false;
      }
      count++;
    }
    return count >= minOnsetRunMinutes;
  }

  /// Whether movement-scored minutes may anchor a session (see
  /// [_isAsleepSample]). Kept as a constant so the two behaviours can be
  /// compared on the same capture.
  static const bool kAnchorOnActigraphy = true;

  /// For a block anchored on actigraphy: how far its median heart rate must
  /// sit below the wearer's waking median. findings-21 measured a ~20 % dip
  /// for flagged sleep; 8 % is a conservative gate that still rejects a still
  /// evening at the desk, where heart rate stays at the waking level.
  static const double restingDipFraction = 0.08;

  /// Median of valid readings between 10:00 and 20:00 across the whole
  /// capture — the wearer's own waking heart rate, used by the gate above.
  static double? _wakingMedianHr(List<HeartRateReading> hr) {
    final v = <int>[];
    for (final r in hr) {
      if (!isValidHr(r.value)) continue;
      final h = r.timestamp.hour;
      if (h >= 10 && h < 20) v.add(r.value);
    }
    if (v.length < 30) return null;
    v.sort();
    final mid = v.length ~/ 2;
    return v.length.isOdd ? v[mid].toDouble() : (v[mid - 1] + v[mid]) / 2.0;
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
    final wakingHr = _wakingMedianHr(hr);
    final hrByMinute = _hrByMinute(hr);
    final blocks = _rawBlocks(sorted, hrByMinute: hrByMinute, wakingHr: wakingHr);

    final days = <SleepDay>[];
    // Sessions must not overlap.
    //
    // `_rawBlocks` splits whenever the sleep-day changes, so a continuous run
    // across 18:00 becomes two *adjacent* blocks with no gap. `_buildSession`
    // then extends each block backwards by up to `restOnsetLookbackMinutes` to
    // find rest onset — and for the second block that walk marches straight
    // back into the first block's minutes, which are asleep, worn and still, so
    // they all qualify. Those minutes were staged and totalled twice.
    //
    // Measured on a synthetic unbroken 16:30→20:30 run: two sessions reporting
    // 89 + 209 = 298 minutes of sleep out of 240 real ones, with the second
    // session starting an hour before the first one ended.
    DateTime? prevEnd;
    for (final block in blocks) {
      final day = _buildSession(block, sorted, hr,
          notBefore: prevEnd, hrByMinute: hrByMinute, wakingHr: wakingHr);
      if (day != null) {
        days.add(day);
        final e = day.endTime;
        if (e != null && (prevEnd == null || e.isAfter(prevEnd))) prevEnd = e;
      }
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
  static List<List<ActivitySample>> _rawBlocks(
    List<ActivitySample> sorted, {
    Map<int, int> hrByMinute = const {},
    double? wakingHr,
  }) {
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

    final intensities = sorted.map((s) => s.intensity).toList();
    for (var i = 0; i < sorted.length; i++) {
      final s = sorted[i];
      if (!_isAsleepSample(s, intensities, i,
          hrByMinute: hrByMinute, wakingHr: wakingHr)) {
        // Wake/nonwear samples never extend a block; whether the block survives
        // is decided by the gap to the next asleep sample below. Measuring the
        // wake time inside the session happens later, in _buildSession.
        continue;
      }

      // A block *opens* only on a sustained run of anchored minutes. An
      // isolated corroborated minute at 21:10 must not start a "night" that a
      // chain of ≤60-minute gaps then carries through to morning — that is how
      // 09-20 became an 809-minute span at 44 % efficiency. Once open, single
      // anchors extend the block as before; sleep onset is the first run of
      // continuous sleep, per the actigraphy convention.
      if (lastAsleep == null && !_sustainedFrom(sorted, intensities, i,
          hrByMinute: hrByMinute, wakingHr: wakingHr)) {
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
    return _splitOverlong(blocks);
  }

  /// Longest span a single night may have before it is split at its longest
  /// internal wake gap. The 99th percentile of adult time-in-bed is under
  /// 12 h; anything longer is two things joined, not one night.
  static const int maxNightSpanMinutes = 12 * 60;

  /// Smallest internal gap worth splitting on. Below this a split would just
  /// produce a fragment that fails [minSessionMinutes] anyway.
  static const int _minSplitGapMinutes = 20;

  /// Splits any block spanning more than [maxNightSpanMinutes] at its longest
  /// internal gap between anchors, repeatedly, until every piece fits.
  ///
  /// This is the actigraphy convention for over-long rest periods, and it is
  /// what separates "dozed on the sofa at 21:10, slept 00:30-07:00, lay in
  /// until 10:39" into the three things it was. Without it 09-20 came out as
  /// one 809-minute span at 41 % efficiency with 22 awakenings — every one of
  /// those numbers true of the block and false of the night.
  static List<List<ActivitySample>> _splitOverlong(
      List<List<ActivitySample>> blocks) {
    final out = <List<ActivitySample>>[];
    final queue = List<List<ActivitySample>>.from(blocks);
    while (queue.isNotEmpty) {
      final b = queue.removeAt(0);
      if (b.length < 2 ||
          b.last.timestamp.difference(b.first.timestamp).inMinutes <=
              maxNightSpanMinutes) {
        out.add(b);
        continue;
      }
      var bestGap = 0, bestAt = -1;
      for (var i = 1; i < b.length; i++) {
        final gap = b[i].timestamp.difference(b[i - 1].timestamp).inMinutes;
        if (gap > bestGap) {
          bestGap = gap;
          bestAt = i;
        }
      }
      if (bestAt < 0 || bestGap < _minSplitGapMinutes) {
        // No usable seam; keep it and let the hard cap decide.
        out.add(b);
        continue;
      }
      queue.insert(0, b.sublist(bestAt));
      queue.insert(0, b.sublist(0, bestAt));
    }
    out.sort((x, y) => x.first.timestamp.compareTo(y.first.timestamp));
    return out;
  }

  /// Turns a candidate block into a [SleepDay], or null if it does not qualify.
  /// [notBefore] is the previous session's end. The backwards rest-onset walk
  /// is clamped to just after it so two adjacent blocks cannot claim the same
  /// minutes.
  static SleepDay? _buildSession(
    List<ActivitySample> block,
    List<ActivitySample> allSorted,
    List<HeartRateReading> hr, {
    DateTime? notBefore,
    Map<int, int> hrByMinute = const {},
    double? wakingHr,
  }) {
    if (block.isEmpty) return null;
    final start = block.first.timestamp;
    final end = block.last.timestamp;
    final spanMinutes = end.difference(start).inMinutes;
    if (spanMinutes < minSessionMinutes) return null;

    // Extend backwards over a bounded "settling down" period so latency and
    // efficiency have a rest interval to be measured against (see
    // [restOnsetLookbackMinutes]), but never back into the previous session.
    var restStart = _restOnset(allSorted, start);
    if (notBefore != null && !restStart.isAfter(notBefore)) {
      restStart = notBefore.add(const Duration(minutes: 1));
      if (restStart.isAfter(start)) restStart = start;
    }

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

    final stages = _classify(window, sessionHr,
        hrByMinute: hrByMinute, wakingHr: wakingHr);
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
    List<ActivitySample> window,
    List<HeartRateReading> sessionHr, {
    Map<int, int> hrByMinute = const {},
    double? wakingHr,
  }) {
    final intensities = window.map((s) => s.intensity).toList();
    final baseline = _hrBaseline(sessionHr);

    final out = <_Staged>[];
    for (var i = 0; i < window.length; i++) {
      final s = window[i];
      if (isNotWorn(s)) {
        out.add(_Staged(s.timestamp, SleepStage.awake));
        continue;
      }
      // Inside a session a minute is awake if the wearer stepped or moved
      // (Chinoy). An *unflagged* still minute is asleep only with the same
      // per-minute corroboration the anchors need — heart rate present and
      // below the waking gate. Without heart rate it stays awake, as before:
      // the band said "not sleep", and stillness alone does not overrule that.
      // On sparse-flag nights the corroborated minutes are what turn a real
      // night from "mostly awake, discarded" into a session.
      if (s.steps > 0 || _weightedSumAwake(intensities, i)) {
        out.add(_Staged(s.timestamp, SleepStage.awake));
        continue;
      }
      if (kindFlags(s.category) != sleepFlagNibble) {
        final bpm = hrByMinute[s.timestamp.millisecondsSinceEpoch ~/ 60000];
        final corroborated = wakingHr != null &&
            bpm != null &&
            bpm <= wakingHr * (1 - restingDipFraction);
        if (!corroborated) {
          out.add(_Staged(s.timestamp, SleepStage.awake));
          continue;
        }
      }
      // Every asleep minute starts as light; depth is decided from the heart
      // rate below, and only there.
      //
      // This used to stage `deep` straight from low nibble 11, on the same
      // discredited reading of the kind byte that `_isAsleepSample` has just
      // dropped — findings-21 measured `0xDB` as carrying the *highest* mean HR
      // of any sleep kind, i.e. sleep onset, not depth. It looked harmless
      // because `_refineWithHeartRate` resets every non-awake minute to light
      // before deciding depth itself, but that function returns early whenever
      // HR coverage is too thin to trust — and on exactly those nights the
      // wrong staging survived into the result.
      out.add(_Staged(s.timestamp, SleepStage.light));
    }

    if (kDeepStagingEnabled && baseline != null) {
      final o = debugDeepOverride;
      _refineWithHeartRate(out, sessionHr, baseline,
          intensities: intensities,
          dipBpm: o?.dipBpm ?? deepDipBpm,
          tauMinutes: o?.tauMinutes ?? processSTauMinutes,
          baselineHalfWindow: o?.baselineHalfWindow ?? _deepBaselineHalfWindow,
          minRunMinutes: o?.minRunMinutes ?? _minDeepRunMinutes,
          wFloor: o?.wFloor ?? processSFloor,
          stillCeiling: o?.stillCeiling ?? deepStillCeiling);
    }
    return out;
  }

  /// Whether deep-sleep staging is presented, **as a labelled estimate**.
  ///
  /// True. The user asked for deep sleep back after findings-24 withdrew it,
  /// and that is their call — but the detector had to change first, because
  /// the old one's output was uniform across the night and so was not finding
  /// slow-wave sleep at all.
  ///
  /// The replacement in [_refineWithHeartRate] builds front-loading into the
  /// model itself via Borbély's two-process framework: the required heart-rate
  /// dip grows as slow-wave propensity decays across the night. It also removes
  /// the circadian drift with a slow trend instead of a cycle-scale rolling
  /// median, which is what made the old residuals negative half the time by
  /// construction.
  ///
  /// This is still an estimate from heart rate and stillness, not a
  /// measurement. Every surface that shows Deep labels it "estimated", the
  /// score weights it below the measured components, and
  /// `tool/analyze_capture.dart` fails if its output stops being front-loaded.
  static const bool kDeepStagingEnabled = true;

  /// Parameter override for `tool/sweep_deep.dart`. Never set in the app.
  static DeepParams? debugDeepOverride;

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

  /// Time constant of slow-wave propensity decay across the night, in minutes.
  ///
  /// Borbély AA. "A two process model of sleep regulation." *Hum Neurobiol*
  /// 1982;1(3):195-204. Process S — homeostatic sleep pressure, of which
  /// slow-wave activity is the physiological marker — declines exponentially
  /// during sleep. Empirically SWA roughly halves from one NREM cycle to the
  /// next, which with ~90-minute cycles puts the time constant near 2-4 hours.
  /// 240 minutes is the upper end of that range and the value the capture
  /// sweep in findings-25 settled on: shorter constants suppressed genuine
  /// late-cycle dips and pushed a third of nights to zero deep.
  ///
  /// It is applied as `requiredDip(t) = deepDipBpm / exp(-t / τ)`: at sleep
  /// onset a minute needs the base dip; 2.5 h in it needs 2.7× that; 5 h in,
  /// 7.4×. Late-night circadian troughs therefore cannot masquerade as deep
  /// sleep unless they are dramatically deeper than anything earlier.
  static const int processSTauMinutes = 240;

  /// Lower bound on the Process-S weight, so the required dip never exceeds
  /// `deepDipBpm / processSFloor`. Without a floor the exponential makes
  /// late-night deep sleep literally impossible, and slow-wave rebound after a
  /// mid-night awakening is real (Borbély's Process S rises again while awake).
  static const double processSFloor = 0.25;

  /// Movement at or below which a minute is still enough to be slow-wave
  /// sleep. Separate from [restIntensityCeiling] (the rest-onset look-back)
  /// because the two answer different questions.
  static const int deepStillCeiling = 12;

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
    double baseline, {
    List<int>? intensities,
    double dipBpm = deepDipBpm,
    int tauMinutes = processSTauMinutes,
    int baselineHalfWindow = _deepBaselineHalfWindow,
    int minRunMinutes = _minDeepRunMinutes,
    double wFloor = processSFloor,
    int stillCeiling = deepStillCeiling,
  }) {
    if (staged.isEmpty) return;

    // Align one smoothed heart rate to each staged minute.
    final series = _alignedHeartRate(staged, hr);
    if (series.whereType<double>().length < 20) {
      return; // too little heart rate to stage on
    }

    // Remove the slow circadian trend, not the cycle-scale structure.
    //
    // Heart rate falls steadily towards a nadir around 04:00-05:00 regardless
    // of stage. Subtracting a wide (±2 h) rolling median takes that out while
    // leaving the ~90-minute troughs that slow-wave sleep produces. A narrower
    // window — the old ±45 min — removed the troughs too, and left residuals
    // that were negative about half the time everywhere (findings-24).
    final residual = baselineHalfWindow == 0
        ? _detrendLinear(series)
        : _detrend(series, baselineHalfWindow);
    if (residual.whereType<double>().length < 20) return;

    // Sleep onset for the time-of-night term: the first non-awake minute.
    var onsetIdx = staged.indexWhere((m) => m.stage != SleepStage.awake);
    if (onsetIdx < 0) onsetIdx = 0;
    final onset = staged[onsetIdx].time;

    // Two-process model: the dip a minute must show grows as Process S decays.
    //
    // requiredDip(t) = dipBpm / exp(-t / τ). This is what makes the estimate
    // front-loaded *by construction* rather than by luck — and it is the same
    // time-since-onset feature the published PPG stagers use (Walch et al.,
    // Sleep 2019;42(12):zsz180, include a clock proxy for exactly this reason).
    double requiredDip(DateTime t) {
      final mins = t.difference(onset).inMinutes.clamp(0, 24 * 60);
      final w = math.exp(-mins / tauMinutes);
      return dipBpm / (w < wFloor ? wFloor : w);
    }

    var runStart = -1;
    void closeRun(int endExclusive) {
      if (runStart < 0) return;
      if (endExclusive - runStart >= minRunMinutes) {
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
      // Anything previously called deep reverts to light unless the evidence
      // below re-establishes it.
      if (staged[i].stage == SleepStage.deep) {
        staged[i] = _Staged(staged[i].time, SleepStage.light);
      }
      // Slow-wave sleep is motionless. A minute with any recorded movement is
      // not a candidate, whatever its heart rate did.
      final still = intensities == null ||
          i >= intensities.length ||
          intensities[i] <= stillCeiling;
      final v = residual[i];
      if (still && v != null && v <= -requiredDip(staged[i].time)) {
        if (runStart < 0) runStart = i;
      } else {
        closeRun(i);
      }
    }
    closeRun(staged.length);
  }

  /// Baseline used to detrend heart rate before thresholding. **0 selects a
  /// whole-session linear fit**, which is what ships.
  ///
  /// Every rolling-median width was tried and none worked, for two different
  /// reasons. Narrow (±45 min, one cycle — the findings-24 detector) makes
  /// about half of all residuals negative wherever you look, so its output is
  /// uniform. Wide (±120-180 min) is biased at the edges: in the first hour
  /// the window is clipped at session start and dominated by the following
  /// two hours, which are *lower* as heart rate settles, so the residual there
  /// is positive and the cycle-1 troughs — where slow-wave sleep is most
  /// concentrated — are never seen. Measured: ±120 min gave 9.3% deep at
  /// position 0.535; the same rule with a linear baseline gave 14.2% at 0.446.
  ///
  /// A least-squares line over the session has no edge and still removes the
  /// monotone circadian drift towards the nadir. See [_detrendLinear].
  static const int _deepBaselineHalfWindow = 0;

  /// Returns `value − linearFit(value)` per minute: the residual against a
  /// straight line fitted over the whole session by least squares.
  ///
  /// A rolling median is biased at the edges — in the first hour its window is
  /// clipped at session start and dominated by the *following* two hours,
  /// which are lower as heart rate settles, so the residual there comes out
  /// positive and cycle-1 troughs (where slow-wave sleep is most concentrated)
  /// are never seen. A single line has no edge and still removes the monotone
  /// circadian drift towards the nadir.
  static List<double?> _detrendLinear(List<double?> series) {
    var n = 0;
    double sx = 0, sy = 0, sxx = 0, sxy = 0;
    for (var i = 0; i < series.length; i++) {
      final v = series[i];
      if (v == null) continue;
      n++;
      sx += i;
      sy += v;
      sxx += i * i.toDouble();
      sxy += i * v;
    }
    if (n < 20) return List<double?>.filled(series.length, null);
    final denom = n * sxx - sx * sx;
    final b = denom == 0 ? 0.0 : (n * sxy - sx * sy) / denom;
    final a = (sy - b * sx) / n;
    return List<double?>.generate(series.length, (i) {
      final v = series[i];
      return v == null ? null : v - (a + b * i);
    });
  }

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

  /// Describes a sleep-day that produced no session even though the band was
  /// worn, so the screen can say "restless, unclassified" instead of showing
  /// a nap. Returns null when a night exists for [sleepDay], when the band
  /// was mostly off the wrist, or when there is too little rest to report.
  ///
  /// This is deliberately *not* a sleep session: nothing here feeds duration,
  /// efficiency, staging or the score. On 2026-09-21→22 the band flagged no
  /// sleep between 22:00 and 06:00 and heart rate sat below the waking gate
  /// for 30-45 minutes of every hour while movement stayed at 40-80 — at rest,
  /// restless, and not something this app can honestly call sleep.
  static RestOnlyNight? restOnlyNight(
    List<ActivitySample> samples,
    List<HeartRateReading> hr,
    DateTime sleepDay, {
    List<SleepDay>? sessions,
  }) {
    final days = sessions ?? detectSessions(samples, hr: hr);
    final d0 = DateTime(sleepDay.year, sleepDay.month, sleepDay.day);
    final hasNight = days.any((d) =>
        !d.isNap &&
        DateTime(d.date.year, d.date.month, d.date.day) == d0);
    if (hasNight) return null;

    final lo = d0.subtract(const Duration(hours: 4)); // 20:00 the evening before
    final hi = d0.add(const Duration(hours: 12));
    final window = samples
        .where((s) => !s.timestamp.isBefore(lo) && s.timestamp.isBefore(hi))
        .toList();
    if (window.length < 240) return null;

    final wakingHr = _wakingMedianHr(hr);
    if (wakingHr == null) return null;
    final gate = wakingHr * (1 - restingDipFraction);
    final hrByMinute = _hrByMinute(hr);

    var worn = 0, withHr = 0, flagged = 0;
    final rest = <DateTime>[];
    for (final s in window) {
      if (isNotWorn(s)) continue;
      worn++;
      final bpm = hrByMinute[s.timestamp.millisecondsSinceEpoch ~/ 60000];
      if (bpm != null) withHr++;
      if (kindFlags(s.category) == sleepFlagNibble) {
        flagged++;
      }
      if (s.steps == 0 && bpm != null && bpm <= gate) rest.add(s.timestamp);
    }
    if (worn < window.length / 2 || rest.length < 120) return null;

    // The rest span is the longest run of consecutive hours with at least
    // half their minutes at rest. Trimming from the window edges was tried
    // first and reported "8:00 PM to 12:00 PM" — this wearer's seated daytime
    // pulse dips under the gate for 15-20 minutes of most hours, so nothing
    // got trimmed. The night itself runs 30-45; half an hour separates them.
    final byHour = <DateTime, int>{};
    for (final t in rest) {
      final h = DateTime(t.year, t.month, t.day, t.hour);
      byHour[h] = (byHour[h] ?? 0) + 1;
    }
    DateTime? bestStart;
    var bestLen = 0, bestMinutes = 0;
    DateTime? runStart;
    var runLen = 0, runMinutes = 0;
    for (var h = DateTime(lo.year, lo.month, lo.day, lo.hour);
        h.isBefore(hi);
        h = h.add(const Duration(hours: 1))) {
      final n = byHour[h] ?? 0;
      if (n >= 30) {
        runStart ??= h;
        runLen++;
        runMinutes += n;
        if (runLen > bestLen) {
          bestLen = runLen;
          bestStart = runStart;
          bestMinutes = runMinutes;
        }
      } else {
        runStart = null;
        runLen = 0;
        runMinutes = 0;
      }
    }
    if (bestStart == null || bestLen < 3) return null; // under three hours

    return RestOnlyNight(
      date: d0,
      start: bestStart,
      end: bestStart.add(Duration(hours: bestLen)),
      restMinutes: bestMinutes,
      wornMinutes: worn,
      hrCoveragePct: (withHr * 100 / worn).round(),
      flaggedMinutes: flagged,
    );
  }

}

/// One minute with its assigned stage.
/// A night the band could not classify as sleep, described by what *was*
/// measured. See [SleepAnalyzer.restOnlyNight].
class RestOnlyNight {
  const RestOnlyNight({
    required this.date,
    required this.start,
    required this.end,
    required this.restMinutes,
    required this.wornMinutes,
    required this.hrCoveragePct,
    required this.flaggedMinutes,
  });

  /// Sleep-day this belongs to (the morning's date).
  final DateTime date;
  final DateTime start;
  final DateTime end;

  /// Minutes in [start, end] with the band worn, no steps, and heart rate
  /// below the waking gate — "at rest", regardless of movement.
  final int restMinutes;
  final int wornMinutes;
  final int hrCoveragePct;

  /// How many minutes the band itself flagged as sleep. Low here is the point.
  final int flaggedMinutes;
}


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

  /// Number of distinct awakenings inside the session lasting at least
  /// [minAwakeningMinutes]. Shorter blips still count towards wake time; they
  /// are not counted as separate awakenings.
  final int wakeEpisodes;

  /// Shortest run of wake minutes reported as an awakening.
  ///
  /// Five minutes is the usual reporting convention in actigraphy, and it is
  /// the length at which the classifier's own output starts agreeing with the
  /// heart rate: below it, "awakenings" carry no HR rise at all.
  static const int minAwakeningMinutes = 5;

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
    // latency and morning wake-up, not awakenings — and only those lasting at
    // least [minAwakeningMinutes].
    //
    // Without the duration floor this counts the classifier flapping. On the
    // night of 2026-08-11 it reported 35 awakenings, of which 18 were exactly
    // one minute long and 20 were two minutes or less; at those 18 minutes the
    // heart rate sat 1.25 bpm BELOW the surrounding median, and only 4 of 16
    // rose by 5 bpm or more. A real arousal raises heart rate. The mechanism is
    // arithmetic: `_weightedSumAwake` scores a minute against a threshold of
    // 10 using its neighbours at 0.2 and 0.04, so one isolated minute of
    // intensity 11 flips to wake on its own — around this night's 85th
    // percentile of sleeping movement.
    //
    // The threshold itself is left alone deliberately: retuning it to make this
    // number look better would be fitting the constant to a prior, and it is
    // Chinoy's validated value. Per-minute wake still counts in full towards
    // WASO and efficiency; only the *count* changes, to the ≥5-minute
    // convention actigraphy studies report.
    var episodes = 0;
    var seenSleep = false;
    for (var i = 0; i < intervals.length; i++) {
      final iv = intervals[i];
      if (iv.stage != SleepStage.awake) {
        seenSleep = true;
        continue;
      }
      if (!seenSleep) continue;
      if (iv.durationMinutes < minAwakeningMinutes) continue;
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

/// Deep-sleep detector parameters, for the capture sweep only.
class DeepParams {
  const DeepParams({
    required this.dipBpm,
    required this.tauMinutes,
    required this.baselineHalfWindow,
    required this.minRunMinutes,
    this.wFloor = SleepAnalyzer.processSFloor,
    this.stillCeiling = SleepAnalyzer.deepStillCeiling,
  });
  final double dipBpm;
  final int tauMinutes;
  final int baselineHalfWindow;
  final int minRunMinutes;
  final double wFloor;
  final int stillCeiling;

  @override
  String toString() =>
      'dip=$dipBpm tau=${tauMinutes}m half=$baselineHalfWindow run=$minRunMinutes floor=$wFloor still=$stillCeiling';
}
