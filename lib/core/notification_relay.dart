import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ble_manager.dart';
import 'logger.dart';

/// A user-facing installed app (for the notification picker).
class AppInfo {
  final String package;
  final String name;
  const AppInfo(this.package, this.name);

  factory AppInfo.fromMap(Map<String, dynamic> m) =>
      AppInfo((m['package'] ?? '').toString(), (m['app'] ?? '').toString());
}

/// Bridges captured Android notifications (from the native
/// BandNotificationListener via the `band/notifications` channel) to the band:
/// receives each posted notification, drops it unless forwarding is enabled and
/// the source app is selected, then sends it through [BLEManager.alertManager].
class NotificationRelay extends ChangeNotifier {
  static const _channel = MethodChannel('band/notifications');
  static const _kEnabled = 'notif_relay_enabled';
  static const _kPackages = 'notif_relay_packages';

  final BLEManager _ble;
  final BLELogger _logger;

  bool _enabled = false;
  bool _accessGranted = false;
  Set<String> _packages = {};
  List<AppInfo> _installedApps = [];
  bool _loadingApps = false;

  NotificationRelay(this._ble, this._logger) {
    _channel.setMethodCallHandler(_onCall);
    _load();
  }

  bool get enabled => _enabled;
  bool get accessGranted => _accessGranted;
  bool get isLoadingApps => _loadingApps;
  Set<String> get selectedPackages => _packages;
  List<AppInfo> get installedApps => _installedApps;
  int get selectedCount => _packages.length;

  // ── Native channel ────────────────────────────────────────────────────────

  Future<dynamic> _onCall(MethodCall call) async {
    if (call.method == 'onNotification') {
      final m = (call.arguments as Map).cast<String, dynamic>();
      _handle(
        (m['package'] ?? '').toString(),
        (m['app'] ?? '').toString(),
        (m['title'] ?? '').toString(),
        (m['text'] ?? '').toString(),
      );
    }
    return null;
  }

  void _handle(String pkg, String app, String title, String text) {
    if (!_enabled) return;
    if (!_packages.contains(pkg)) return;
    if (!_ble.isConnected || _ble.authState != AuthState.authenticated) {
      _logger.d('Notif relay: dropped "$app" (band not ready)');
      return;
    }
    _logger.i('Notif relay: forwarding "$app" — $title');
    _ble.alertManager.sendAppNotification(app.isEmpty ? pkg : app, title, text);
  }

  /// True if the user has granted "Notification access" to this app.
  Future<bool> refreshAccess() async {
    try {
      _accessGranted =
          await _channel.invokeMethod<bool>('isAccessGranted') ?? false;
    } catch (_) {
      _accessGranted = false;
    }
    notifyListeners();
    return _accessGranted;
  }

  Future<void> openAccessSettings() async {
    try {
      await _channel.invokeMethod('openAccessSettings');
    } catch (e) {
      _logger.e('Notif relay: openAccessSettings failed: $e');
    }
  }

  Future<void> refreshInstalledApps() async {
    _loadingApps = true;
    notifyListeners();
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('getInstalledApps');
      _installedApps = (raw ?? [])
          .map((e) => AppInfo.fromMap((e as Map).cast<String, dynamic>()))
          .toList();
    } catch (e) {
      _logger.e('Notif relay: getInstalledApps failed: $e');
    } finally {
      _loadingApps = false;
      notifyListeners();
    }
  }

  // ── Settings ──────────────────────────────────────────────────────────────

  Future<void> setEnabled(bool value) async {
    _enabled = value;
    notifyListeners();
    await _save();
    if (value) await refreshAccess();
  }

  bool isAppSelected(String package) => _packages.contains(package);

  Future<void> setAppSelected(String package, bool selected) async {
    if (selected) {
      _packages.add(package);
    } else {
      _packages.remove(package);
    }
    notifyListeners();
    await _save();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    _enabled = p.getBool(_kEnabled) ?? false;
    _packages = (p.getStringList(_kPackages) ?? const []).toSet();
    notifyListeners();
    await refreshAccess();
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kEnabled, _enabled);
    await p.setStringList(_kPackages, _packages.toList());
  }

  /// Send a sample notification to the band (developer/test).
  void sendTest() => _ble.alertManager.sendTest();
}
