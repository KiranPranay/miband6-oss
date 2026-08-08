import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'logger.dart';

/// Result of checking what the OS currently allows us to do in the background.
class BackgroundPermissionState {
  const BackgroundPermissionState({
    required this.notificationsGranted,
    required this.ignoringBatteryOptimizations,
  });

  /// Android 13+ POST_NOTIFICATIONS. Without it the foreground service still
  /// runs but shows no notification — which both hides the connection state and
  /// makes the process a more likely target for reclamation.
  final bool notificationsGranted;

  /// Whether the app is exempt from Doze. Without the exemption Android
  /// suspends the process for long stretches while the phone is idle, which is
  /// precisely when overnight sleep tracking needs the link alive.
  final bool ignoringBatteryOptimizations;

  /// True when the band can be expected to stay connected in the background.
  bool get isFullyPermitted =>
      notificationsGranted && ignoringBatteryOptimizations;
}

/// Thin wrapper over the platform permission checks needed for a reliable
/// background BLE connection.
///
/// Deliberately does **not** prompt on its own: the battery-optimization
/// dialog is a system screen that looks alarming without context, so callers
/// show an explanation first and then call [requestBatteryExemption]. The app
/// keeps working (foreground only) if the user declines.
class BackgroundPermissions {
  const BackgroundPermissions(this._logger);

  final BLELogger _logger;

  Future<BackgroundPermissionState> check() async {
    var notifications = false;
    var battery = false;
    try {
      notifications = await FlutterForegroundTask.checkNotificationPermission()
          .then((p) => p == NotificationPermission.granted);
    } catch (e) {
      _logger.d('Permissions: notification check failed: $e');
    }
    try {
      battery = await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    } catch (e) {
      _logger.d('Permissions: battery-optimization check failed: $e');
    }
    return BackgroundPermissionState(
      notificationsGranted: notifications,
      ignoringBatteryOptimizations: battery,
    );
  }

  /// Requests POST_NOTIFICATIONS (Android 13+). Safe to call repeatedly: the
  /// platform returns the existing decision without re-prompting.
  Future<bool> requestNotifications() async {
    try {
      final result = await FlutterForegroundTask.requestNotificationPermission();
      final granted = result == NotificationPermission.granted;
      _logger.i('Permissions: notifications ${granted ? 'granted' : result.name}');
      return granted;
    } catch (e) {
      _logger.e('Permissions: notification request failed: $e');
      return false;
    }
  }

  /// Opens the system battery-optimization exemption prompt.
  ///
  /// Call only after telling the user why. Returns the state afterwards, which
  /// may still be `false` if they declined — that is a legitimate choice, not
  /// an error, and the caller should degrade rather than nag.
  Future<bool> requestBatteryExemption() async {
    try {
      if (await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
        return true;
      }
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      final now = await FlutterForegroundTask.isIgnoringBatteryOptimizations;
      _logger.i('Permissions: battery exemption ${now ? 'granted' : 'declined'}');
      return now;
    } catch (e) {
      _logger.e('Permissions: battery exemption request failed: $e');
      return false;
    }
  }
}
