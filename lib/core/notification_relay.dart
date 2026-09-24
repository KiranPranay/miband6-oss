import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ble_manager.dart';
import 'call_session.dart';
import 'logger.dart';

/// A user-facing installed app (for the notification picker).
class AppInfo {
  final String package;
  final String name;
  const AppInfo(this.package, this.name);

  factory AppInfo.fromMap(Map<String, dynamic> m) =>
      AppInfo((m['package'] ?? '').toString(), (m['app'] ?? '').toString());
}

/// Why a captured notification was not forwarded. Surfaced in the log so the
/// end-to-end path can be diagnosed from a single grep rather than guessed at.
enum RelayDecision {
  forwarded,
  relayDisabled,
  appNotSelected,
  bandNotReady,
  duplicate,
  screenOn,

  /// A CATEGORY_CALL notification: handed to the [CallSession] for the
  /// caller's name, never forwarded as a message. See `call_session.dart`.
  callRouted,
}

/// Bridges captured Android notifications to the band.
///
/// Receives each posted notification from the native `BandNotificationListener`
/// over the `band/notifications` channel (registered on the process-lifetime
/// engine — see `BandApplication.kt`), decides whether to forward it, and sends
/// it through [BLEManager.alertManager].
///
/// Every decision is logged with a `Notif relay:` prefix, because the previous
/// version dropped notifications in three different places with no trace, which
/// made "nothing appears on the band" impossible to diagnose (findings-17).
class NotificationRelay extends ChangeNotifier {
  static const _channel = MethodChannel('band/notifications');
  static const _kEnabled = 'notif_relay_enabled';
  static const _kPackages = 'notif_relay_packages';
  static const _kPrivacy = 'notif_relay_privacy';
  static const _kSuppressScreenOn = 'notif_relay_suppress_screen_on';

  /// How long an identical notification is suppressed. Apps re-post the same
  /// notification on every minor update (typing indicators, download progress,
  /// a second message in the same thread), and each re-post would otherwise
  /// buzz the wrist again.
  static const Duration dedupWindow = Duration(seconds: 30);

  /// Bound on the dedup table so a long uptime cannot grow it without limit.
  static const int _maxDedupEntries = 64;

  /// Null only for [NotificationRelay.detached].
  final BLEManager? _ble;
  final BLELogger _logger;

  bool _enabled = false;
  bool _accessGranted = false;
  bool _privacyMode = false;
  bool _suppressWhenScreenOn = false;
  Set<String> _packages = {};
  List<AppInfo> _installedApps = [];
  bool _loadingApps = false;

  final Map<String, DateTime> _recentlySent = {};

  /// Last decision made, for the diagnostics row in Settings.
  RelayDecision? _lastDecision;
  String? _lastDecisionApp;
  DateTime? _lastDecisionAt;

  /// When the band is told about a call, and once. Fed by telephony through
  /// `CallControl.listenCallState`; the dialer's notification only names the
  /// caller.
  late final CallSession callSession =
      CallSession(sink: _BandCallSink(this), logger: _logger);

  NotificationRelay(BLEManager ble, this._logger) : _ble = ble {
    _channel.setMethodCallHandler(_onCall);
    ble.callControl.listenCallState(_onPhoneCallState);
    ble.callControl.startCallState();
    _load();
  }

  /// A relay with no band and no platform channel behind it, pre-filled with
  /// [apps]. Lets the picker screen be pumped in a widget test without
  /// standing up Bluetooth, secure storage or the notification listener.
  @visibleForTesting
  NotificationRelay.detached(
    this._logger, {
    List<AppInfo> apps = const [],
    bool accessGranted = false,
    bool enabled = false,
    Set<String> selected = const {},
  }) : _ble = null {
    _installedApps = apps;
    _accessGranted = accessGranted;
    _enabled = enabled;
    _packages = {...selected};
  }

  /// Connected and authenticated — the only state in which a write to the
  /// band's alert characteristic means anything.
  bool get _bandReady {
    final b = _ble;
    return b != null && b.isConnected && b.authState == AuthState.authenticated;
  }

  bool get enabled => _enabled;
  bool get accessGranted => _accessGranted;
  bool get isLoadingApps => _loadingApps;
  bool get privacyMode => _privacyMode;
  bool get suppressWhenScreenOn => _suppressWhenScreenOn;
  Set<String> get selectedPackages => _packages;
  List<AppInfo> get installedApps => _installedApps;
  int get selectedCount => _packages.length;
  RelayDecision? get lastDecision => _lastDecision;
  String? get lastDecisionApp => _lastDecisionApp;
  DateTime? get lastDecisionAt => _lastDecisionAt;

  // ── Native channel ────────────────────────────────────────────────────────

  Future<dynamic> _onCall(MethodCall call) async {
    if (call.method == 'onNotification') {
      final m = (call.arguments as Map).cast<String, dynamic>();
      await handle(
        package: (m['package'] ?? '').toString(),
        app: (m['app'] ?? '').toString(),
        title: (m['title'] ?? '').toString(),
        text: (m['text'] ?? '').toString(),
        isCall: m['isCall'] == true,
      );
    }
    return null;
  }

  void _onPhoneCallState(String event) {
    final e = PhoneCallEvent.parse(event);
    if (e == null) {
      _logger.e('Call: unknown phone event "$event"');
      return;
    }
    if (!_enabled && e == PhoneCallEvent.ringing) {
      _logger.i('Call: ringing, but forwarding is off');
      return;
    }
    callSession.onPhoneEvent(e);
    // Decline-with-text reads the number from the band's owner.
    _ble?.lastIncomingCallNumber = callSession.callerNumber;
  }

  /// Decide on and possibly forward one notification.
  ///
  /// Returns the decision so the hardware test session and unit tests can
  /// assert on it rather than scraping logs.
  @visibleForTesting
  Future<RelayDecision> handle({
    required String package,
    required String app,
    required String title,
    required String text,
    bool isCall = false,
  }) async {
    final label = app.isEmpty ? package : app;

    // A call notification never reaches the band on its own. Telephony says
    // when a call is ringing (CallStateHost.kt → CallSession); the dialer's
    // notification only tells us who is calling, because the telephony
    // callback carries no number on modern Android. It is re-posted on every
    // timer tick and hold, and posted for outgoing calls too — alerting on it
    // is exactly the bug this replaced.
    if (isCall) {
      callSession.onCallNotification(title: title, text: text);
      _ble?.lastIncomingCallNumber = callSession.callerNumber;
      return _record(RelayDecision.callRouted, label);
    }

    final decision = await _decide(package, label, title, text);
    _lastDecision = decision;
    _lastDecisionApp = label;
    _lastDecisionAt = DateTime.now();

    if (decision == RelayDecision.forwarded) {
      // Privacy mode sends the app + title only, never the message body — for
      // a wrist display in public that is usually the right default.
      final body = _privacyMode ? '' : text;
      _logger.i('Notif relay: forwarding "$label" — $title'
          '${_privacyMode ? ' (privacy: title only)' : ''}');
      await _ble!.alertManager.sendAppNotification(
        label,
        title,
        body,
        package: package,
      );
    } else {
      _logger.i('Notif relay: dropped "$label" — ${decision.name}');
    }
    notifyListeners();
    return decision;
  }

  RelayDecision _record(RelayDecision d, String label) {
    _lastDecision = d;
    _lastDecisionApp = label;
    _lastDecisionAt = DateTime.now();
    notifyListeners();
    return d;
  }

  /// A dialable number from notification text, or null. Dialers show a saved
  /// contact's *name* rather than the number, in which case there is nothing to
  /// capture and decline-with-text has no target — the log says so.
  Future<RelayDecision> _decide(
      String package, String label, String title, String text) async {
    if (!_enabled) return RelayDecision.relayDisabled;
    if (!_packages.contains(package)) return RelayDecision.appNotSelected;

    if (!_bandReady) {
      // Deliberately dropped rather than queued: a notification delivered ten
      // minutes late is noise, not information.
      return RelayDecision.bandNotReady;
    }

    if (_isDuplicate(package, title, text)) return RelayDecision.duplicate;

    if (_suppressWhenScreenOn && await _isScreenOn()) {
      return RelayDecision.screenOn;
    }

    return RelayDecision.forwarded;
  }

  /// True when the same app/title/body was forwarded within [dedupWindow].
  bool _isDuplicate(String package, String title, String text) {
    // NUL separators — as escapes, so the file stays plain text for tooling.
    final key = '$package\u0000$title\u0000$text';
    final now = DateTime.now();
    _recentlySent.removeWhere((_, at) => now.difference(at) > dedupWindow);
    if (_recentlySent.containsKey(key)) return true;

    if (_recentlySent.length >= _maxDedupEntries) {
      // Evict the oldest so the map stays bounded.
      String? oldestKey;
      DateTime? oldestAt;
      _recentlySent.forEach((k, at) {
        if (oldestAt == null || at.isBefore(oldestAt!)) {
          oldestAt = at;
          oldestKey = k;
        }
      });
      if (oldestKey != null) _recentlySent.remove(oldestKey);
    }
    _recentlySent[key] = now;
    return false;
  }

  Future<bool> _isScreenOn() async {
    try {
      return await _channel.invokeMethod<bool>('isScreenOn') ?? false;
    } catch (_) {
      return false;
    }
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

  /// Ask Android to re-bind the listener service.
  ///
  /// Android unbinds notification listeners after updates, low memory or a
  /// crash and does not reliably come back; this is the documented recovery.
  Future<void> requestRebind() async {
    try {
      final ok = await _channel.invokeMethod<bool>('requestRebind') ?? false;
      _logger.i('Notif relay: requested listener rebind (accepted=$ok)');
    } catch (e) {
      _logger.e('Notif relay: requestRebind failed: $e');
    }
  }

  Future<void> refreshInstalledApps() async {
    _loadingApps = true;
    notifyListeners();
    try {
      final raw =
          await _channel.invokeMethod<List<dynamic>>('getInstalledApps');
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

  Future<void> setPrivacyMode(bool value) async {
    _privacyMode = value;
    notifyListeners();
    await _save();
  }

  Future<void> setSuppressWhenScreenOn(bool value) async {
    _suppressWhenScreenOn = value;
    notifyListeners();
    await _save();
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
    _privacyMode = p.getBool(_kPrivacy) ?? false;
    _suppressWhenScreenOn = p.getBool(_kSuppressScreenOn) ?? false;
    _packages = (p.getStringList(_kPackages) ?? const []).toSet();
    notifyListeners();
    await refreshAccess();
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kEnabled, _enabled);
    await p.setBool(_kPrivacy, _privacyMode);
    await p.setBool(_kSuppressScreenOn, _suppressWhenScreenOn);
    await p.setStringList(_kPackages, _packages.toList());
  }

  /// Send a sample notification to the band (developer/test). Bypasses the
  /// listener entirely, so it isolates the BLE half of the path from the
  /// Android half.
  void sendTest() => _ble?.alertManager.sendTest();
}

/// The band as a [CallSink]: ANS call alert on, ANS call alert off.
class _BandCallSink implements CallSink {
  _BandCallSink(this._relay);
  final NotificationRelay _relay;

  @override
  bool get ready => _relay._bandReady;

  @override
  Future<void> showIncoming(String caller) =>
      _relay._ble!.alertManager.sendIncomingCall(caller);

  @override
  Future<void> clear() => _relay._ble!.alertManager.stopCall();
}
