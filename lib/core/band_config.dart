import 'dart:convert';
import 'dart:typed_data';

/// Which characteristic a config command must be written to.
///
/// Getting this wrong is silent: the band accepts the write and ignores it.
enum ConfigTarget {
  /// fee1 `00000003-…` — almost every setting.
  configuration,

  /// fee1 `00000008-…` — wear location, user info, step goal.
  userSettings,

  /// Standard Heart Rate Control Point `0x2A39` — all HR mode/interval commands.
  heartRateControl,

  /// Immediate Alert `0x2A06` — vibrate/find band.
  alertLevel,

  /// fee1 `00000020-…` old-chunked — display items, vibration patterns.
  chunked,
}

/// One built command: the bytes and where they go.
class BandCommand {
  const BandCommand(this.target, this.bytes, this.label);

  final ConfigTarget target;
  final List<int> bytes;

  /// Human-readable description for the log and for optimistic-UI rollback.
  final String label;

  @override
  String toString() =>
      '$label → ${target.name}: ${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}';
}

/// Periodic heart-rate measurement interval.
///
/// Mi Band 6 restricts the choices to these values
/// (`MiBand6Coordinator.getHeartRateMeasurementIntervals`).
enum HrInterval {
  off(0),
  oneMinute(1),
  fiveMinutes(5),
  tenMinutes(10),
  thirtyMinutes(30);

  const HrInterval(this.minutes);

  /// The value written to the band — **minutes**, not seconds.
  final int minutes;

  String get label => this == HrInterval.off ? 'Off' : '$minutes min';
}

enum WearWrist { left, right }

enum DistanceUnit { metric, imperial }

enum TimeFormat { twelveHour, twentyFourHour }

enum DndMode { off, automatic, scheduled }

enum NightMode { off, sunset, scheduled }

enum LiftWristMode { off, always, scheduled }

enum LiftWristSensitivity { normal, sensitive }

/// A local time of day, used by the scheduled settings.
class BandTime {
  const BandTime(this.hour, this.minute);
  final int hour;
  final int minute;

  int get h => hour.clamp(0, 23);
  int get m => minute.clamp(0, 59);

  @override
  String toString() =>
      '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
}

/// Builders for every Mi Band 6 configuration command.
///
/// **Pure** — each method returns bytes and a target; nothing here touches BLE.
/// That keeps the byte layouts unit-testable, which matters because a wrong
/// config byte is not an error: the band simply ignores it, and the setting
/// silently does nothing.
///
/// Everything is on the **legacy** Huami path
/// (`MiBand6Support → MiBand5Support → MiBand4Support → MiBand3Support →
/// AmazfitBipSupport → HuamiSupport`). Sources are cited per command; the full
/// table is in `protocol-mb6.md` §9.
///
/// ## Deliberately absent
///
/// * **SpO2 all-day monitoring** and **sleep-breathing quality** — these exist
///   only as ZeppOS config items (`ZeppOsConfigService`, HEALTH ids 0x31/0x12).
///   There is no legacy equivalent, so they are not offered rather than shipped
///   as a switch that does nothing.
/// * **Low heart-rate alert** — `setHeartrateAlert` encodes only the *high*
///   threshold on this path; the low value is never written.
/// * **Hourly chime** — not sent for MB6.
class BandCommands {
  const BandCommands._();

  // ── Heart rate (Heart Rate Control Point 0x2A39) ─────────────────────────

  /// Periodic/automatic HR measurement interval.
  ///
  /// `{0x14, minutes}` — `COMMAND_SET_PERIODIC_HR_MEASUREMENT_INTERVAL`.
  /// GB's UI passes seconds and divides by 60; the wire value is **minutes**,
  /// clamped 0..120. `0` disables periodic measurement.
  static BandCommand hrInterval(HrInterval interval) => BandCommand(
        ConfigTarget.heartRateControl,
        [0x14, interval.minutes.clamp(0, 120)],
        'HR interval ${interval.label}',
      );

  /// Sleep-assisted HR monitoring — `{0x15, 0x00, on}`.
  ///
  /// The `0x15` opcode is a shared HR-mode setter on 0x2A39: sub-byte
  /// `0x00` = sleep-assisted, `0x01` = continuous/realtime, `0x02` = manual.
  static BandCommand hrSleepAssisted(bool enabled) => BandCommand(
        ConfigTarget.heartRateControl,
        [0x15, 0x00, enabled ? 0x01 : 0x00],
        'HR sleep-assisted ${enabled ? 'on' : 'off'}',
      );

  /// All-day activity HR monitoring — `{0x06, 0x22, 0x00, on}`.
  static BandCommand hrAllDayMonitoring(bool enabled) => BandCommand(
        ConfigTarget.configuration,
        [0x06, 0x22, 0x00, enabled ? 0x01 : 0x00],
        'HR all-day monitoring ${enabled ? 'on' : 'off'}',
      );

  /// High heart-rate alert — `{0x06, 0x1a, 0x00, on, bpm}`.
  ///
  /// Threshold is raw BPM (GB default 150). There is **no low-HR alert** on
  /// the legacy path.
  static BandCommand hrHighAlert(bool enabled, int thresholdBpm) => BandCommand(
        ConfigTarget.configuration,
        [0x06, 0x1a, 0x00, enabled ? 0x01 : 0x00, thresholdBpm.clamp(0, 255)],
        'HR high alert ${enabled ? '$thresholdBpm bpm' : 'off'}',
      );

  /// All-day stress monitoring — `{0xFE, 0x06, 0x00, on}`.
  ///
  /// `MiBand6Coordinator.supportsStressMeasurement()` is true, so this is a
  /// real MB6 setting (and it is what populates the stress fetch types).
  static BandCommand stressMonitoring(bool enabled) => BandCommand(
        ConfigTarget.configuration,
        [0xFE, 0x06, 0x00, enabled ? 0x01 : 0x00],
        'Stress monitoring ${enabled ? 'on' : 'off'}',
      );

  // ── Display ──────────────────────────────────────────────────────────────

  /// Lift wrist to wake.
  ///
  /// OFF is **4 bytes**; ON/SCHEDULED are **8**, with a zeroed schedule meaning
  /// "always". Sending the 8-byte form with zeros is how GB expresses "always
  /// on" — it is not the same as OFF.
  static BandCommand liftWrist(
    LiftWristMode mode, {
    BandTime start = const BandTime(0, 0),
    BandTime end = const BandTime(0, 0),
  }) {
    switch (mode) {
      case LiftWristMode.off:
        return const BandCommand(
          ConfigTarget.configuration,
          [0x06, 0x05, 0x00, 0x00],
          'Lift wrist off',
        );
      case LiftWristMode.always:
        return const BandCommand(
          ConfigTarget.configuration,
          [0x06, 0x05, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00],
          'Lift wrist always',
        );
      case LiftWristMode.scheduled:
        return BandCommand(
          ConfigTarget.configuration,
          [0x06, 0x05, 0x00, 0x01, start.h, start.m, end.h, end.m],
          'Lift wrist $start–$end',
        );
    }
  }

  /// Lift-wrist sensitivity — `{0x06, 0x23, 0x00, 0|1}`.
  static BandCommand liftWristSensitivity(LiftWristSensitivity s) =>
      BandCommand(
        ConfigTarget.configuration,
        [0x06, 0x23, 0x00, s == LiftWristSensitivity.sensitive ? 0x01 : 0x00],
        'Lift sensitivity ${s.name}',
      );

  /// Time format — `{0x06, 0x02, 0x00, 0|1}`.
  static BandCommand timeFormat(TimeFormat f) => BandCommand(
        ConfigTarget.configuration,
        [0x06, 0x02, 0x00, f == TimeFormat.twentyFourHour ? 0x01 : 0x00],
        f == TimeFormat.twentyFourHour ? '24-hour time' : '12-hour time',
      );

  /// Show date alongside time — `{0x06, 0x0a, 0x00, 0x00|0x03}`.
  static BandCommand showDate(bool show) => BandCommand(
        ConfigTarget.configuration,
        [0x06, 0x0A, 0x00, show ? 0x03 : 0x00],
        show ? 'Show date + time' : 'Show time only',
      );

  /// Date format — `{0x06, 0x1e, 0x00}` + **exactly 10 ASCII bytes**.
  ///
  /// GB's own implementation copies into a shared static array without cloning
  /// it, permanently mutating the constant for the process. We build a fresh
  /// list each call instead.
  static BandCommand dateFormat(String pattern) {
    // Pad/truncate to 10 so the command length is always 13.
    final ascii = latin1.encode(pattern).toList();
    while (ascii.length < 10) {
      ascii.add(0x00);
    }
    return BandCommand(
      ConfigTarget.configuration,
      [0x06, 0x1E, 0x00, ...ascii.take(10)],
      'Date format $pattern',
    );
  }

  /// Distance unit — `{0x06, 0x03, 0x00, 0|1}`.
  static BandCommand distanceUnit(DistanceUnit u) => BandCommand(
        ConfigTarget.configuration,
        [0x06, 0x03, 0x00, u == DistanceUnit.imperial ? 0x01 : 0x00],
        'Units ${u.name}',
      );

  /// Which wrist the band is worn on.
  ///
  /// `{0x20, 0x00, 0x00, 0x02}` left / `0x82` right — and note this goes to the
  /// **user-settings** characteristic (`0x0008`), not the config one.
  static BandCommand wearWrist(WearWrist wrist) => BandCommand(
        ConfigTarget.userSettings,
        [0x20, 0x00, 0x00, wrist == WearWrist.right ? 0x82 : 0x02],
        'Worn on ${wrist.name} wrist',
      );

  /// Daily step goal — `{0x10, 0x00, 0x00, lo, hi, 0x00, 0x00}` (uint16 LE),
  /// to the user-settings characteristic.
  static BandCommand stepGoal(int steps) {
    final g = steps.clamp(0, 65535);
    return BandCommand(
      ConfigTarget.userSettings,
      [0x10, 0x00, 0x00, g & 0xFF, (g >> 8) & 0xFF, 0x00, 0x00],
      'Step goal $g',
    );
  }

  /// Goal-reached notification — `{0x06, 0x06, 0x00, 0|1}`.
  static BandCommand goalNotification(bool enabled) => BandCommand(
        ConfigTarget.configuration,
        [0x06, 0x06, 0x00, enabled ? 0x01 : 0x00],
        'Goal notification ${enabled ? 'on' : 'off'}',
      );

  // ── Do not disturb / night mode ──────────────────────────────────────────

  /// Do-not-disturb — endpoint `0x09`.
  ///
  /// `OFF = {09 82}`, `AUTOMATIC = {09 83}`,
  /// `SCHEDULED = {09 81 sH sM eH eM}`. When the band is allowed to still wake
  /// on a wrist lift during DND, **bit 0x80 of byte 1 is cleared**
  /// (`0x81 → 0x01`, `0x83 → 0x03`).
  static BandCommand doNotDisturb(
    DndMode mode, {
    BandTime start = const BandTime(1, 0),
    BandTime end = const BandTime(6, 0),
    bool allowLiftWrist = false,
  }) {
    int flag(int base) => allowLiftWrist ? base & 0x7F : base;
    switch (mode) {
      case DndMode.off:
        // OFF has no lift-wrist variant — there is nothing to suppress.
        return const BandCommand(
          ConfigTarget.configuration,
          [0x09, 0x82],
          'DND off',
        );
      case DndMode.automatic:
        return BandCommand(
          ConfigTarget.configuration,
          [0x09, flag(0x83)],
          'DND automatic',
        );
      case DndMode.scheduled:
        return BandCommand(
          ConfigTarget.configuration,
          [0x09, flag(0x81), start.h, start.m, end.h, end.m],
          'DND $start–$end',
        );
    }
  }

  /// Night mode (dim display) — top-level opcode `0x1a`, separate from DND.
  static BandCommand nightMode(
    NightMode mode, {
    BandTime start = const BandTime(22, 0),
    BandTime end = const BandTime(7, 0),
  }) {
    switch (mode) {
      case NightMode.off:
        return const BandCommand(
            ConfigTarget.configuration, [0x1A, 0x00], 'Night mode off');
      case NightMode.sunset:
        return const BandCommand(
            ConfigTarget.configuration, [0x1A, 0x02], 'Night mode at sunset');
      case NightMode.scheduled:
        return BandCommand(
          ConfigTarget.configuration,
          [0x1A, 0x01, start.h, start.m, end.h, end.m],
          'Night mode $start–$end',
        );
    }
  }

  // ── Inactivity ───────────────────────────────────────────────────────────

  /// Inactivity ("move") warnings — opcode `0x08`, **12 bytes**.
  ///
  /// Layout (`HuamiService.COMMAND_ENABLE_INACTIVITY_WARNINGS`):
  /// `[0]=0x08 [1]=enable [2]=threshold minutes [3]=0`
  /// `[4..7]  = window 1 startH, startM, endH, endM`
  /// `[8..11] = window 2 startH, startM, endH, endM` (zero when unused)
  ///
  /// Two windows exist so a DND period can be carved out of the middle of the
  /// active period; with no carve-out only window 1 is filled.
  static BandCommand inactivityWarnings({
    required bool enabled,
    int thresholdMinutes = 60,
    BandTime start = const BandTime(8, 0),
    BandTime end = const BandTime(22, 0),
    BandTime? dndStart,
    BandTime? dndEnd,
  }) {
    if (!enabled) {
      return const BandCommand(
        ConfigTarget.configuration,
        [0x08, 0x00, 0x3C, 0x00, 0x04, 0x00, 0x15, 0x00, 0, 0, 0, 0],
        'Inactivity warnings off',
      );
    }
    final t = thresholdMinutes.clamp(1, 255);
    if (dndStart != null && dndEnd != null) {
      return BandCommand(
        ConfigTarget.configuration,
        [
          0x08, 0x01, t, 0x00, //
          start.h, start.m, dndStart.h, dndStart.m,
          dndEnd.h, dndEnd.m, end.h, end.m,
        ],
        'Inactivity every ${t}m, $start–$end (quiet $dndStart–$dndEnd)',
      );
    }
    return BandCommand(
      ConfigTarget.configuration,
      [
        0x08, 0x01, t, 0x00, //
        start.h, start.m, end.h, end.m,
        0, 0, 0, 0,
      ],
      'Inactivity every ${t}m, $start–$end',
    );
  }

  // ── Misc ─────────────────────────────────────────────────────────────────

  /// One-shot vibration — `{0x03}` to Immediate Alert `0x2A06`.
  static const BandCommand vibrate =
      BandCommand(ConfigTarget.alertLevel, [0x03], 'Vibrate');

  /// Stop the vibration / alert — `{0x00}` to `0x2A06`.
  static const BandCommand stopVibrate =
      BandCommand(ConfigTarget.alertLevel, [0x00], 'Stop vibration');

  /// Display item order — `0x1e` then 4 bytes per entry
  /// `{index, 0x00, menuType, itemId}`, sent over **legacy chunked type 2**.
  ///
  /// `menuType` `0xFF` = main menu, `0xFD` = shortcuts. Ids come from
  /// `HuamiMenuType.idLookup`.
  static BandCommand displayItems(List<int> itemIds) {
    final bytes = <int>[0x1E];
    for (var i = 0; i < itemIds.length; i++) {
      bytes.addAll([i, 0x00, 0xFF, itemIds[i] & 0xFF]);
    }
    return BandCommand(
      ConfigTarget.chunked,
      bytes,
      'Display items (${itemIds.length})',
    );
  }

  /// Menu item ids (`HuamiMenuType.idLookup`) usable with [displayItems].
  static const Map<String, int> menuItems = {
    'status': 0x01,
    'heartRate': 0x02,
    'workout': 0x03,
    'weather': 0x04,
    'watchface': 0x12,
    'stress': 0x1C,
    'sleep': 0x23,
    'spo2': 0x24,
  };
}

/// The user's chosen band settings.
///
/// Persisted locally and **re-applied on every reconnect** — the band loses some
/// of these across a reset, and Gadgetbridge likewise re-sends its settings on
/// each connect rather than only at pairing time.
class BandSettings {
  const BandSettings({
    this.hrInterval = HrInterval.off,
    this.hrSleepAssisted = false,
    this.hrAllDayMonitoring = false,
    this.hrHighAlertEnabled = false,
    this.hrHighAlertBpm = 150,
    this.stressMonitoring = false,
    this.liftWrist = LiftWristMode.off,
    this.liftWristStart = const BandTime(8, 0),
    this.liftWristEnd = const BandTime(22, 0),
    this.liftWristSensitivity = LiftWristSensitivity.normal,
    this.timeFormat = TimeFormat.twentyFourHour,
    this.showDate = true,
    this.dateFormat = 'dd/MM/yyyy',
    this.distanceUnit = DistanceUnit.metric,
    this.wearWrist = WearWrist.left,
    this.stepGoal = 10000,
    this.goalNotification = true,
    this.dnd = DndMode.off,
    this.dndStart = const BandTime(1, 0),
    this.dndEnd = const BandTime(6, 0),
    this.dndAllowLiftWrist = false,
    this.nightMode = NightMode.off,
    this.nightModeStart = const BandTime(22, 0),
    this.nightModeEnd = const BandTime(7, 0),
    this.inactivityEnabled = false,
    this.inactivityThresholdMinutes = 60,
    this.inactivityStart = const BandTime(8, 0),
    this.inactivityEnd = const BandTime(22, 0),
  });

  final HrInterval hrInterval;
  final bool hrSleepAssisted;
  final bool hrAllDayMonitoring;
  final bool hrHighAlertEnabled;
  final int hrHighAlertBpm;
  final bool stressMonitoring;
  final LiftWristMode liftWrist;
  final BandTime liftWristStart;
  final BandTime liftWristEnd;
  final LiftWristSensitivity liftWristSensitivity;
  final TimeFormat timeFormat;
  final bool showDate;
  final String dateFormat;
  final DistanceUnit distanceUnit;
  final WearWrist wearWrist;
  final int stepGoal;
  final bool goalNotification;
  final DndMode dnd;
  final BandTime dndStart;
  final BandTime dndEnd;
  final bool dndAllowLiftWrist;
  final NightMode nightMode;
  final BandTime nightModeStart;
  final BandTime nightModeEnd;
  final bool inactivityEnabled;
  final int inactivityThresholdMinutes;
  final BandTime inactivityStart;
  final BandTime inactivityEnd;

  /// Every command needed to bring a freshly-connected band to this state.
  ///
  /// Ordered so the cheap display settings land first and the HR/stress
  /// monitoring commands (which the band may take a moment over) come last.
  List<BandCommand> toCommands() => [
        BandCommands.timeFormat(timeFormat),
        BandCommands.showDate(showDate),
        BandCommands.dateFormat(dateFormat),
        BandCommands.distanceUnit(distanceUnit),
        BandCommands.wearWrist(wearWrist),
        BandCommands.stepGoal(stepGoal),
        BandCommands.goalNotification(goalNotification),
        BandCommands.liftWrist(
          liftWrist,
          start: liftWristStart,
          end: liftWristEnd,
        ),
        BandCommands.liftWristSensitivity(liftWristSensitivity),
        BandCommands.nightMode(
          nightMode,
          start: nightModeStart,
          end: nightModeEnd,
        ),
        BandCommands.doNotDisturb(
          dnd,
          start: dndStart,
          end: dndEnd,
          allowLiftWrist: dndAllowLiftWrist,
        ),
        BandCommands.inactivityWarnings(
          enabled: inactivityEnabled,
          thresholdMinutes: inactivityThresholdMinutes,
          start: inactivityStart,
          end: inactivityEnd,
        ),
        BandCommands.hrAllDayMonitoring(hrAllDayMonitoring),
        BandCommands.hrSleepAssisted(hrSleepAssisted),
        BandCommands.hrHighAlert(hrHighAlertEnabled, hrHighAlertBpm),
        BandCommands.stressMonitoring(stressMonitoring),
        // Last: this is the one whose effect is externally observable in the
        // next fetch, so it is the natural hardware-verification hook.
        BandCommands.hrInterval(hrInterval),
      ];

  BandSettings copyWith({
    HrInterval? hrInterval,
    bool? hrSleepAssisted,
    bool? hrAllDayMonitoring,
    bool? hrHighAlertEnabled,
    int? hrHighAlertBpm,
    bool? stressMonitoring,
    LiftWristMode? liftWrist,
    BandTime? liftWristStart,
    BandTime? liftWristEnd,
    LiftWristSensitivity? liftWristSensitivity,
    TimeFormat? timeFormat,
    bool? showDate,
    String? dateFormat,
    DistanceUnit? distanceUnit,
    WearWrist? wearWrist,
    int? stepGoal,
    bool? goalNotification,
    DndMode? dnd,
    BandTime? dndStart,
    BandTime? dndEnd,
    bool? dndAllowLiftWrist,
    NightMode? nightMode,
    BandTime? nightModeStart,
    BandTime? nightModeEnd,
    bool? inactivityEnabled,
    int? inactivityThresholdMinutes,
    BandTime? inactivityStart,
    BandTime? inactivityEnd,
  }) =>
      BandSettings(
        hrInterval: hrInterval ?? this.hrInterval,
        hrSleepAssisted: hrSleepAssisted ?? this.hrSleepAssisted,
        hrAllDayMonitoring: hrAllDayMonitoring ?? this.hrAllDayMonitoring,
        hrHighAlertEnabled: hrHighAlertEnabled ?? this.hrHighAlertEnabled,
        hrHighAlertBpm: hrHighAlertBpm ?? this.hrHighAlertBpm,
        stressMonitoring: stressMonitoring ?? this.stressMonitoring,
        liftWrist: liftWrist ?? this.liftWrist,
        liftWristStart: liftWristStart ?? this.liftWristStart,
        liftWristEnd: liftWristEnd ?? this.liftWristEnd,
        liftWristSensitivity:
            liftWristSensitivity ?? this.liftWristSensitivity,
        timeFormat: timeFormat ?? this.timeFormat,
        showDate: showDate ?? this.showDate,
        dateFormat: dateFormat ?? this.dateFormat,
        distanceUnit: distanceUnit ?? this.distanceUnit,
        wearWrist: wearWrist ?? this.wearWrist,
        stepGoal: stepGoal ?? this.stepGoal,
        goalNotification: goalNotification ?? this.goalNotification,
        dnd: dnd ?? this.dnd,
        dndStart: dndStart ?? this.dndStart,
        dndEnd: dndEnd ?? this.dndEnd,
        dndAllowLiftWrist: dndAllowLiftWrist ?? this.dndAllowLiftWrist,
        nightMode: nightMode ?? this.nightMode,
        nightModeStart: nightModeStart ?? this.nightModeStart,
        nightModeEnd: nightModeEnd ?? this.nightModeEnd,
        inactivityEnabled: inactivityEnabled ?? this.inactivityEnabled,
        inactivityThresholdMinutes:
            inactivityThresholdMinutes ?? this.inactivityThresholdMinutes,
        inactivityStart: inactivityStart ?? this.inactivityStart,
        inactivityEnd: inactivityEnd ?? this.inactivityEnd,
      );

  Map<String, dynamic> toJson() => {
        'hrInterval': hrInterval.name,
        'hrSleepAssisted': hrSleepAssisted,
        'hrAllDayMonitoring': hrAllDayMonitoring,
        'hrHighAlertEnabled': hrHighAlertEnabled,
        'hrHighAlertBpm': hrHighAlertBpm,
        'stressMonitoring': stressMonitoring,
        'liftWrist': liftWrist.name,
        'liftWristStart': [liftWristStart.h, liftWristStart.m],
        'liftWristEnd': [liftWristEnd.h, liftWristEnd.m],
        'liftWristSensitivity': liftWristSensitivity.name,
        'timeFormat': timeFormat.name,
        'showDate': showDate,
        'dateFormat': dateFormat,
        'distanceUnit': distanceUnit.name,
        'wearWrist': wearWrist.name,
        'stepGoal': stepGoal,
        'goalNotification': goalNotification,
        'dnd': dnd.name,
        'dndStart': [dndStart.h, dndStart.m],
        'dndEnd': [dndEnd.h, dndEnd.m],
        'dndAllowLiftWrist': dndAllowLiftWrist,
        'nightMode': nightMode.name,
        'nightModeStart': [nightModeStart.h, nightModeStart.m],
        'nightModeEnd': [nightModeEnd.h, nightModeEnd.m],
        'inactivityEnabled': inactivityEnabled,
        'inactivityThresholdMinutes': inactivityThresholdMinutes,
        'inactivityStart': [inactivityStart.h, inactivityStart.m],
        'inactivityEnd': [inactivityEnd.h, inactivityEnd.m],
      };

  static T _enumOf<T extends Enum>(List<T> values, Object? name, T fallback) {
    for (final v in values) {
      if (v.name == name) return v;
    }
    return fallback;
  }

  static BandTime _timeOf(Object? raw, BandTime fallback) {
    if (raw is List && raw.length == 2) {
      return BandTime((raw[0] as num).toInt(), (raw[1] as num).toInt());
    }
    return fallback;
  }

  factory BandSettings.fromJson(Map<String, dynamic> j) {
    const d = BandSettings();
    return BandSettings(
      hrInterval: _enumOf(HrInterval.values, j['hrInterval'], d.hrInterval),
      hrSleepAssisted: j['hrSleepAssisted'] as bool? ?? d.hrSleepAssisted,
      hrAllDayMonitoring:
          j['hrAllDayMonitoring'] as bool? ?? d.hrAllDayMonitoring,
      hrHighAlertEnabled:
          j['hrHighAlertEnabled'] as bool? ?? d.hrHighAlertEnabled,
      hrHighAlertBpm: (j['hrHighAlertBpm'] as num?)?.toInt() ?? d.hrHighAlertBpm,
      stressMonitoring: j['stressMonitoring'] as bool? ?? d.stressMonitoring,
      liftWrist: _enumOf(LiftWristMode.values, j['liftWrist'], d.liftWrist),
      liftWristStart: _timeOf(j['liftWristStart'], d.liftWristStart),
      liftWristEnd: _timeOf(j['liftWristEnd'], d.liftWristEnd),
      liftWristSensitivity: _enumOf(LiftWristSensitivity.values,
          j['liftWristSensitivity'], d.liftWristSensitivity),
      timeFormat: _enumOf(TimeFormat.values, j['timeFormat'], d.timeFormat),
      showDate: j['showDate'] as bool? ?? d.showDate,
      dateFormat: j['dateFormat'] as String? ?? d.dateFormat,
      distanceUnit:
          _enumOf(DistanceUnit.values, j['distanceUnit'], d.distanceUnit),
      wearWrist: _enumOf(WearWrist.values, j['wearWrist'], d.wearWrist),
      stepGoal: (j['stepGoal'] as num?)?.toInt() ?? d.stepGoal,
      goalNotification: j['goalNotification'] as bool? ?? d.goalNotification,
      dnd: _enumOf(DndMode.values, j['dnd'], d.dnd),
      dndStart: _timeOf(j['dndStart'], d.dndStart),
      dndEnd: _timeOf(j['dndEnd'], d.dndEnd),
      dndAllowLiftWrist: j['dndAllowLiftWrist'] as bool? ?? d.dndAllowLiftWrist,
      nightMode: _enumOf(NightMode.values, j['nightMode'], d.nightMode),
      nightModeStart: _timeOf(j['nightModeStart'], d.nightModeStart),
      nightModeEnd: _timeOf(j['nightModeEnd'], d.nightModeEnd),
      inactivityEnabled:
          j['inactivityEnabled'] as bool? ?? d.inactivityEnabled,
      inactivityThresholdMinutes:
          (j['inactivityThresholdMinutes'] as num?)?.toInt() ??
              d.inactivityThresholdMinutes,
      inactivityStart: _timeOf(j['inactivityStart'], d.inactivityStart),
      inactivityEnd: _timeOf(j['inactivityEnd'], d.inactivityEnd),
    );
  }

  /// Bytes of the whole command set, for logging/diagnostics.
  Uint8List debugBytes() =>
      Uint8List.fromList(toCommands().expand((c) => c.bytes).toList());
}
