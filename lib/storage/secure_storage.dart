import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/logger.dart';
import '../core/band_metrics.dart';

class StorageManager {
  static const FlutterSecureStorage _storage = FlutterSecureStorage();
  static const String _authKeyKey = "mi_band_auth_key";
  static const String _lastDeviceKey = "mi_band_last_device_id";
  static const String _wantsConnectedKey = "mi_band_wants_connected";
  static const String _wantsHrStreamKey = "mi_band_wants_hr_stream";

  // SharedPreferences keys for activity metrics
  static const String _stepsKey = "mi_band_steps";
  static const String _distanceKey = "mi_band_distance";
  static const String _caloriesKey = "mi_band_calories";
  static const String _lastSyncKey = "mi_band_last_sync";

  final BLELogger _logger;

  StorageManager(this._logger);

  // ── Auth key ──────────────────────────────────────────────────────────────

  Future<void> saveAuthKey(String hexKey) async {
    try {
      final bytes = hexToBytes(hexKey);
      await _storage.write(key: _authKeyKey, value: base64Encode(bytes));
      _logger.i("Auth key saved successfully to secure storage as base64.");
    } catch (e) {
      _logger.e("Failed to encode/save key: $e");
    }
  }

  Future<String?> getAuthKey() async {
    return await _storage.read(key: _authKeyKey);
  }

  Future<Uint8List?> getAuthKeyBytes() async {
    final stored = await _storage.read(key: _authKeyKey);
    if (stored != null) {
      try {
        final authKeyBytes = base64Decode(stored);
        _logger.d(
            "Retrieved auth key from storage, length: ${authKeyBytes.length}");
        return authKeyBytes;
      } catch (e) {
        _logger.e("Error decoding base64 key.");
        return null;
      }
    } else {
      _logger.d("No auth key found in storage.");
      return null;
    }
  }

  Future<void> clearAuthKey() async {
    await _storage.delete(key: _authKeyKey);
    _logger.i("Auth key cleared from storage.");
  }

  // ── Last device ───────────────────────────────────────────────────────────

  /// Saves the MAC address of the last successfully connected band.
  Future<void> saveLastDeviceId(String deviceId) async {
    await _storage.write(key: _lastDeviceKey, value: deviceId);
    _logger.d("Last device saved: $deviceId");
  }

  /// Returns the saved device MAC, or null if none saved.
  Future<String?> getLastDeviceId() async {
    return await _storage.read(key: _lastDeviceKey);
  }

  /// Clears the saved device MAC (call on explicit user disconnect).
  Future<void> clearLastDeviceId() async {
    await _storage.delete(key: _lastDeviceKey);
    _logger.d("Last device cleared.");
  }

  // ── Connection intent ─────────────────────────────────────────────────────

  /// Records whether the user wants the band connected.
  ///
  /// This is *intent*, not state: it survives app restarts, process death and
  /// foreground-service revival, so the supervisor knows on cold start whether
  /// to start reconnecting without waiting for the user to open a screen.
  Future<void> setWantsConnected(bool value) async {
    await _storage.write(key: _wantsConnectedKey, value: value ? '1' : '0');
  }

  /// True when a band is paired and the user has not explicitly disconnected.
  /// Defaults to true when a device MAC is stored but the flag was never
  /// written — i.e. bands paired before this flag existed keep working.
  Future<bool> getWantsConnected() async {
    final raw = await _storage.read(key: _wantsConnectedKey);
    if (raw == null) return (await getLastDeviceId())?.isNotEmpty ?? false;
    return raw == '1';
  }

  /// Whether the user wants continuous (1 Hz) realtime heart-rate streaming.
  ///
  /// Persisted because it is a *power* decision, not just a UI toggle: the
  /// realtime stream is the band's workout-grade mode and drains it in hours.
  /// If this were not remembered, any app restart — a crash, a system kill,
  /// an overnight OOM — would silently resume streaming and flatten the band
  /// before morning.
  Future<void> setWantsHrStreaming(bool value) async {
    await _storage.write(key: _wantsHrStreamKey, value: value ? '1' : '0');
  }

  /// Defaults to true so existing installs behave as before.
  Future<bool> getWantsHrStreaming() async =>
      (await _storage.read(key: _wantsHrStreamKey)) != '0';

  // ── Activity metrics ──────────────────────────────────────────────────────

  /// Persists the latest activity metrics to SharedPreferences.
  Future<void> saveMetrics(BandMetrics metrics) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_stepsKey, metrics.steps);
      await prefs.setInt(_distanceKey, metrics.distanceMeters);
      await prefs.setInt(_caloriesKey, metrics.calories);
      _logger.d(
          "Metrics saved: ${metrics.steps} steps, ${metrics.distanceMeters} m, ${metrics.calories} kcal");
    } catch (e) {
      _logger.e("Failed to save metrics: $e");
    }
  }

  /// Loads persisted activity metrics. Returns null if never saved.
  Future<BandMetrics?> loadMetrics() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final steps = prefs.getInt(_stepsKey);
      if (steps == null) return null; // never been saved
      final distance = prefs.getInt(_distanceKey) ?? 0;
      final calories = prefs.getInt(_caloriesKey) ?? 0;
      _logger.d("Metrics loaded: $steps steps, $distance m, $calories kcal");
      return BandMetrics(
          steps: steps, distanceMeters: distance, calories: calories);
    } catch (e) {
      _logger.e("Failed to load metrics: $e");
      return null;
    }
  }

  /// Saves the timestamp of the last successful metrics sync.
  Future<void> saveLastSyncTime(DateTime time) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_lastSyncKey, time.millisecondsSinceEpoch);
    } catch (e) {
      _logger.e("Failed to save last sync time: $e");
    }
  }

  /// Loads the timestamp of the last successful metrics sync.
  Future<DateTime?> loadLastSyncTime() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ms = prefs.getInt(_lastSyncKey);
      if (ms == null) return null;
      return DateTime.fromMillisecondsSinceEpoch(ms);
    } catch (e) {
      _logger.e("Failed to load last sync time: $e");
      return null;
    }
  }

  /// Converts a 32-character hex string to a 16-byte Uint8List.
  static Uint8List hexToBytes(String hexString) {
    hexString = hexString.replaceAll(" ", "");
    if (hexString.length != 32) {
      throw Exception("Auth key must be 32 hex chars");
    }
    var bytes = Uint8List(16);
    for (int i = 0; i < 16; i++) {
      bytes[i] = int.parse(hexString.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }
}
