import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'band_config.dart';
import 'logger.dart';

/// Writes a [BandCommand] to the band. Implemented by [BLEManager]; kept as a
/// narrow interface so the controller is testable without a BLE stack.
abstract class BandCommandWriter {
  /// Returns true when the write was accepted by the GATT layer.
  ///
  /// Note this only means "the band took the bytes" — the band silently ignores
  /// commands it does not understand, so a `true` here is **not** proof the
  /// setting took effect. That is what the hardware gate is for.
  Future<bool> writeBandCommand(BandCommand command);

  /// True when the band is connected and authenticated.
  bool get canConfigure;
}

/// Owns the user's band settings: persists them, writes them to the band, and
/// re-applies them on every reconnect.
///
/// ## Optimistic UI with rollback
///
/// [update] applies the change locally and notifies immediately, so a toggle
/// responds instantly, then writes to the band. If the write fails the previous
/// value is restored and [lastError] is set — the switch visibly flips back
/// rather than lying about a setting that never landed.
class BandConfigController extends ChangeNotifier {
  BandConfigController(this._logger, this._writer) {
    _load();
  }

  static const _prefsKey = 'band_settings_v1';

  final BLELogger _logger;
  final BandCommandWriter _writer;

  BandSettings _settings = const BandSettings();
  BandSettings get settings => _settings;

  bool _loaded = false;
  bool get isLoaded => _loaded;

  bool _applying = false;
  bool get isApplying => _applying;

  String? _lastError;
  String? get lastError => _lastError;

  DateTime? _lastAppliedAt;
  DateTime? get lastAppliedAt => _lastAppliedAt;

  // ── Persistence ──────────────────────────────────────────────────────────

  Future<void> _load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_prefsKey);
      if (raw != null) {
        _settings = BandSettings.fromJson(
            jsonDecode(raw) as Map<String, dynamic>);
      }
    } catch (e) {
      _logger.e('BandConfig: failed to load settings: $e');
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _persist() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_prefsKey, jsonEncode(_settings.toJson()));
    } catch (e) {
      _logger.e('BandConfig: failed to persist settings: $e');
    }
  }

  // ── Applying ─────────────────────────────────────────────────────────────

  /// Change one or more settings, write the difference to the band, and roll
  /// back on failure.
  Future<bool> update(BandSettings next) async {
    final previous = _settings;
    _settings = next;
    _lastError = null;
    notifyListeners(); // optimistic

    await _persist();

    if (!_writer.canConfigure) {
      // Not an error: the setting is saved and will be applied on connect.
      _logger.i('BandConfig: band not ready — settings saved, will apply on '
          'next connect');
      return true;
    }

    final changed = _changedCommands(previous, next);
    if (changed.isEmpty) return true;

    final ok = await _write(changed);
    if (!ok) {
      _settings = previous;
      _lastError = 'The band did not accept that change.';
      await _persist();
      notifyListeners();
    }
    return ok;
  }

  /// Only the commands whose bytes actually differ between two states.
  ///
  /// Avoids re-writing a dozen unchanged settings every time one toggle moves.
  List<BandCommand> _changedCommands(BandSettings a, BandSettings b) {
    final before = a.toCommands();
    final after = b.toCommands();
    final out = <BandCommand>[];
    for (var i = 0; i < after.length; i++) {
      if (i >= before.length ||
          !listEquals(before[i].bytes, after[i].bytes)) {
        out.add(after[i]);
      }
    }
    return out;
  }

  /// Re-send every setting. Called after each successful authentication: the
  /// band loses some settings across a reset, so a reconnect must restore the
  /// user's configuration rather than leaving the band on its defaults.
  Future<void> applyAll({String reason = 'reconnect'}) async {
    if (!_writer.canConfigure) return;
    if (!_loaded) await _load();
    _logger.i('BandConfig: re-applying all settings ($reason)');
    await _write(_settings.toCommands());
  }

  Future<bool> _write(List<BandCommand> commands) async {
    _applying = true;
    notifyListeners();
    var allOk = true;
    try {
      for (final c in commands) {
        final ok = await _writer.writeBandCommand(c);
        if (!ok) {
          allOk = false;
          _logger.e('BandConfig: write FAILED — $c');
        }
      }
      _lastAppliedAt = DateTime.now();
    } catch (e) {
      allOk = false;
      _lastError = '$e';
      _logger.e('BandConfig: apply threw: $e');
    } finally {
      _applying = false;
      notifyListeners();
    }
    return allOk;
  }

  /// Configure the band for an unattended overnight recording.
  ///
  /// Continuous realtime HR (the `0x2A37` stream) samples about once a second,
  /// which is superb data and a terrible idea overnight: it is the band's
  /// workout-grade mode and flattens the battery in a few hours. The band can
  /// instead sample *internally* at a fixed cadence for a fraction of the power
  /// and hand the whole night over on the next fetch.
  ///
  /// So sleep capture means: stop streaming, and turn on the on-band monitors
  /// that actually populate the overnight record —
  ///  * periodic HR at [interval] (1 min gives ~480 points a night, which is
  ///    what the stage estimator needs);
  ///  * sleep-assisted HR, the firmware's own denser-while-asleep mode;
  ///  * all-day HR, so the record does not stop at the session edges;
  ///  * all-day stress, without which fetch type 0x13 returns nothing at all.
  ///
  /// Returns the settings that were applied.
  Future<BandSettings> applySleepCaptureMode({
    HrInterval interval = HrInterval.oneMinute,
  }) async {
    _logger.i('BandConfig: entering SLEEP CAPTURE mode '
        '(periodic HR ${interval.label}, sleep-assisted + all-day HR + stress on, '
        'realtime streaming off)');
    final next = _settings.copyWith(
      hrInterval: interval,
      hrSleepAssisted: true,
      hrAllDayMonitoring: true,
      stressMonitoring: true,
    );
    await update(next);
    return next;
  }

  // ── Convenience setters used by the settings screen ──────────────────────

  Future<bool> setHrInterval(HrInterval v) =>
      update(_settings.copyWith(hrInterval: v));

  Future<bool> setStressMonitoring(bool v) =>
      update(_settings.copyWith(stressMonitoring: v));

  // ── Experimental probes (protocol-mb6.md §13-14) ───────────────────────────
  //
  // Each is sent only while on, and the outcome is recorded in the ledger
  // (P13.1, P14.2). Off by default; the UI says "experimental".

  Future<bool> setSpo2AutoMonitoring(bool v) =>
      update(_settings.copyWith(spo2AutoMonitoring: v));

  Future<bool> setCannedRepliesEnabled(bool v) =>
      update(_settings.copyWith(cannedRepliesEnabled: v));

  Future<bool> setCannedReplies(List<String> messages) => update(
      _settings.copyWith(cannedReplies: messages.map((m) => m.trim()).where((m) => m.isNotEmpty).take(16).toList()));

  Future<bool> setHrAllDayMonitoring(bool v) =>
      update(_settings.copyWith(hrAllDayMonitoring: v));

  Future<bool> setHrSleepAssisted(bool v) =>
      update(_settings.copyWith(hrSleepAssisted: v));

  Future<bool> setLiftWrist(LiftWristMode v) =>
      update(_settings.copyWith(liftWrist: v));

  Future<bool> setTimeFormat(TimeFormat v) =>
      update(_settings.copyWith(timeFormat: v));

  Future<bool> setDistanceUnit(DistanceUnit v) =>
      update(_settings.copyWith(distanceUnit: v));

  Future<bool> setWearWrist(WearWrist v) =>
      update(_settings.copyWith(wearWrist: v));

  Future<bool> setStepGoal(int v) => update(_settings.copyWith(stepGoal: v));

  Future<bool> setGoalNotification(bool v) =>
      update(_settings.copyWith(goalNotification: v));

  Future<bool> setDnd(DndMode v) => update(_settings.copyWith(dnd: v));

  Future<bool> setNightMode(NightMode v) =>
      update(_settings.copyWith(nightMode: v));

  Future<bool> setInactivityEnabled(bool v) =>
      update(_settings.copyWith(inactivityEnabled: v));

  Future<bool> setHrHighAlert(bool enabled, int bpm) => update(
      _settings.copyWith(hrHighAlertEnabled: enabled, hrHighAlertBpm: bpm));
}
