import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'dart:math';
import 'logger.dart';
import 'reconnect_backoff.dart';
import 'call_control.dart';
import 'device_events.dart';
import '../storage/band_event_store.dart';
import 'encryption.dart';
import '../storage/secure_storage.dart';
import 'band_metrics.dart';
import 'activity_sample.dart';
import 'activity_fetcher.dart';
import '../storage/activity_store.dart';
import 'alert_manager.dart';
import 'background_permissions.dart';
import 'band_config.dart';
import 'band_config_controller.dart';
import 'ecdh_b163.dart';
import 'heart_rate_measurement.dart';
import 'huami2021_chunked.dart';
import 'huami_icon.dart';
import 'sleep_analyzer.dart';
import 'ui_throttle.dart';

part 'hardware_test_session.dart';
part 'huami2021_auth.dart';
part 'connection_supervisor.dart';

// Top-level callback required by flutter_foreground_task
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(MyTaskHandler());
}

class MyTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}
  @override
  void onRepeatEvent(DateTime timestamp) {}
  @override
  Future<void> onDestroy(DateTime timestamp) async {}
}

enum AuthState { notAuthenticated, authenticating, authenticated, failed }

class BLEManager extends ChangeNotifier implements BandCommandWriter {
  final BLELogger _logger;
  final StorageManager _storage;

  BluetoothDevice? _device;
  BluetoothCharacteristic? _authChar;
  BluetoothCharacteristic? _stepsChar;
  BluetoothCharacteristic? _alertChar;

  // Heart rate (standard GATT 0x180D service — see protocol-mb6.md §3)
  BluetoothCharacteristic? _hrMeasureChar; // 0x2A37 (notify)
  BluetoothCharacteristic? _hrControlChar; // 0x2A39 (write)
  BluetoothCharacteristic? _battChar; // fee0/0x0006 (Huami battery)

  StreamSubscription<BluetoothConnectionState>? _connSubscription;
  StreamSubscription<List<int>>? _charSubscription;
  StreamSubscription<List<int>>? _stepsSubscription;
  StreamSubscription<List<int>>? _hrSubscription;

  /// Battery and init-characteristic notifies.
  ///
  /// These were fire-and-forget `listen()` calls with nothing holding the
  /// subscription, so each reconnect added another live listener on the same
  /// characteristic — the same leak that broke history sync entirely when it
  /// happened to `ActivityFetcher`. Harmless here in effect (they only log or
  /// set the battery level) but they accumulate for the life of the process.
  StreamSubscription<List<int>>? _battSubscription;
  final List<StreamSubscription<List<int>>> _initCharSubs = [];

  /// The supervisor's current connection attempt, while one is running.
  /// Three triggers fire within milliseconds of start-up — the initial
  /// attempt, the adapter-state replay, the heartbeat — and each used to
  /// issue its own GATT connect; two then ran the sign-key handshake on the
  /// same link and the band refused the second (status 0x25). See
  /// `_attemptConnect`.
  Future<void>? _connectAttemptInFlight;
  Timer? _authTimeoutTimer;
  Timer? _reconnectTimer;
  Timer? _hrKeepAliveTimer;
  bool _realtimeHrActive = false;

  /// Whether the user wants continuous HR streaming. Distinct from
  /// [_realtimeHrActive], which is whether it is *currently* running: after a
  /// reconnect the intent is what decides whether to re-arm streaming.
  bool _userWantsHrStreaming = true;

  // Hardware test session (see hardware_test_session.dart). Exposed so the UI
  // can disable the trigger button while a session is in progress.
  bool _isTestSessionRunning = false;
  bool get isTestSessionRunning => _isTestSessionRunning;

  // Huami 2021 sign-key auth + encrypted chunked transport (see
  // huami2021_auth.dart). Used when the band exposes fee0/0x0016+0x0017.
  BluetoothCharacteristic? _chunkedWriteChar; // fee0/0x0016
  BluetoothCharacteristic? _chunkedNotifyChar; // fee0/0x0017
  StreamSubscription<List<int>>? _chunkedSub;
  Huami2021ChunkedEncoder? _chunkedEncoder;
  Huami2021ChunkedDecoder? _chunkedDecoder;
  Uint8List? _privateEC;
  Uint8List? _sessionKey; // derived shared session AES key (post sign-key auth)
  int _mtu = 247;
  bool get isSignKeyAuth => _chunkedEncoder != null;
  Uint8List? get sessionKey => _sessionKey;

  bool _isReconnecting = false;
  bool _userDisconnected = false;

  // ── Connection supervision (see connection_supervisor.dart) ───────────────

  /// True while the user wants a live connection. Persisted, so the app
  /// resumes supervising on its own after a restart or a service revival.
  bool _userWantsConnected = false;

  /// Retry schedule for the connection supervisor (1 → 2 → 5 → 15 → 30 → 60 s
  /// with jitter, then held at the cap, retried indefinitely).
  final ReconnectBackoff _backoff = ReconnectBackoff();

  /// When we last heard *anything* from the band. Used to detect the half-open
  /// link where GATT still claims "connected" but no data ever arrives.
  DateTime? _lastPacketAt;

  Timer? _heartbeatTimer;
  StreamSubscription<BluetoothAdapterState>? _adapterSub;

  ConnectionPhase _connectionPhase = ConnectionPhase.idle;
  ConnectionPhase get connectionPhase => _connectionPhase;

  /// The single, explicit connection state for the UI and the persistent
  /// notification to render.
  final ValueNotifier<ConnectionPhase> connectionPhaseListenable =
      ValueNotifier<ConnectionPhase>(ConnectionPhase.idle);

  void _setPhase(ConnectionPhase phase) {
    if (_connectionPhase == phase) return;
    _connectionPhase = phase;
    connectionPhaseListenable.value = phase;
    _isReconnecting = phase == ConnectionPhase.waitingToRetry ||
        phase == ConnectionPhase.connecting;
    _emitChange();
  }

  /// Records inbound traffic for the liveness heartbeat. Called from every
  /// notification/read path.
  void _markPacket() => _lastPacketAt = DateTime.now();

  BandMetrics _metrics = const BandMetrics();
  int? _batteryLevel;
  int? _heartRate;
  /// How far the health **history** has actually been pulled from the band.
  ///
  /// This is what "Last sync just now" on the Today card and in the persistent
  /// notification means, so it must only ever mirror
  /// `activityStore.lastActivitySync`.
  ///
  /// It used to be re-stamped with `DateTime.now()` from two places that have
  /// nothing to do with history: every realtime step packet (the notify
  /// subscription plus a 2-minute poll) and every live heart-rate beat. So the
  /// one staleness indicator the app has reported "just now" continuously while
  /// the actual history sync was frozen — which is exactly what happened
  /// between 2026-08-17 and 08-21, and why nothing on screen suggested anything
  /// was wrong for five days.
  DateTime? _lastSyncTime;

  /// Phone-side actions for the band's buttons (protocol-mb6.md §12.1).
  late final CallControl callControl = CallControl(_logger);

  /// The band's own sleep/wear boundaries, persisted as evidence (§12).
  final BandEventStore bandEvents = BandEventStore();

  /// Set while the band has asked us to ring (§12.2), cleared on stop.
  bool _findPhoneActive = false;

  /// Decline-with-text message (§13.3), cached from storage; null = off.
  String? _declineText;
  String? get declineText => _declineText;
  Future<void> setDeclineText(String? text) async {
    _declineText = (text == null || text.trim().isEmpty) ? null : text.trim();
    await _storage.setDeclineText(_declineText);
    _emitChange();
  }

  /// The number from the most recent incoming-call notification, recorded by
  /// the notification relay so a band-side decline can reply by SMS. Null when
  /// the dialer's notification carried no number (a saved contact usually
  /// shows a name instead).
  String? lastIncomingCallNumber;

  /// Most recent decoded device event, for the UI/debug console.
  final ValueNotifier<BandEvent?> lastBandEvent = ValueNotifier(null);

  ActivityFetcher? _activityFetcher;

  /// The device [_activityFetcher] was built for, so a reconnection to a
  /// different band rebuilds it rather than reusing subscriptions on
  /// characteristics that no longer exist.
  BluetoothDevice? _fetcherDevice;
  final ActivityStore activityStore = ActivityStore();
  late final AlertManager alertManager = AlertManager(_logger);
  late final BackgroundPermissions _backgroundPermissions =
      BackgroundPermissions(_logger);

  /// Exposed so Settings can show the current background-permission state and
  /// offer the battery-optimization exemption with an explanation.
  BackgroundPermissions get backgroundPermissions => _backgroundPermissions;

  /// Owns the user's band settings and re-applies them after every auth.
  /// Wired here (rather than in `main`) so the re-apply hook cannot be
  /// forgotten by a caller.
  late final BandConfigController bandConfig =
      BandConfigController(_logger, this);

  // ── BandCommandWriter ────────────────────────────────────────────────────

  @override
  bool get canConfigure =>
      isConnected && _authState == AuthState.authenticated;

  /// Writes one configuration command to the characteristic it belongs to.
  ///
  /// Routing matters and is easy to get wrong silently: HR commands go to the
  /// standard Heart Rate Control Point, wear-location/step-goal to the
  /// user-settings characteristic, and everything else to the config
  /// characteristic. A command written to the wrong one is accepted and
  /// ignored. See `protocol-mb6.md` §9.
  @override
  Future<bool> writeBandCommand(BandCommand command) async {
    if (!canConfigure) {
      _logger.d('BandConfig: skipped "${command.label}" — band not ready');
      return false;
    }
    // Chunked-2021 goes through the framing encoder, not a bare
    // characteristic write. Only the experimental probes use it (§13-14), and
    // only after sign-key auth has established the encoder + session key.
    if (command.target == ConfigTarget.chunked2021) {
      if (_chunkedEncoder == null) {
        _logger.e('BandConfig: chunked-2021 encoder not ready — '
            'cannot write "${command.label}"');
        return false;
      }
      await _writeChunked(command.endpoint, Uint8List.fromList(command.bytes),
          encrypt: command.encrypt);
      _logger.i('BandConfig: $command (endpoint 0x${command.endpoint.toRadixString(16)}'
          '${command.encrypt ? ', encrypted' : ''})');
      return true;
    }
    final ch = await _characteristicFor(command.target);
    if (ch == null) {
      _logger.e('BandConfig: no characteristic for ${command.target.name} '
          '— cannot write "${command.label}"');
      return false;
    }
    try {
      // Several Huami characteristics only advertise write-without-response;
      // using write-with-response there throws (findings-05).
      final noResp = !ch.properties.write && ch.properties.writeWithoutResponse;
      await ch.write(command.bytes, withoutResponse: noResp);
      _logger.i('BandConfig: $command');
      return true;
    } catch (e) {
      _logger.e('BandConfig: write failed for "${command.label}": $e');
      return false;
    }
  }

  Future<BluetoothCharacteristic?> _characteristicFor(
      ConfigTarget target) async {
    switch (target) {
      case ConfigTarget.configuration:
        return _findChar('fee0', '0003');
      case ConfigTarget.userSettings:
        return _findChar('fee0', '0008');
      case ConfigTarget.heartRateControl:
        if (_hrControlChar != null) return _hrControlChar;
        return _findChar('180d', '2a39');
      case ConfigTarget.alertLevel:
        return _findChar('1802', '2a06');
      case ConfigTarget.chunked:
        return _alertChar ?? await _findChar('fee0', '0020');
      case ConfigTarget.chunked2021:
        return null; // handled in writeBandCommand via the encoder
    }
  }
  bool _isFetchingActivity = false;

  bool get isConnected => _device != null && _device!.isConnected;
  bool _isAuthenticating = false;
  AuthState _authState = AuthState.notAuthenticated;

  // ---------------------------------------------------------------------------
  // Fine-grained UI state (findings-15)
  //
  // The high-frequency values each get their own [ValueNotifier] so a widget can
  // subscribe to exactly what it renders. Previously every one of these updates
  // went through `notifyListeners()` on this ChangeNotifier, and every tab did a
  // top-level `context.watch<BLEManager>()` — so one streamed heartbeat rebuilt
  // the entire 2 000-line sleep tab, re-running its full analysis pass.
  //
  // `notifyListeners()` is still emitted for coarse/structural changes, but is
  // coalesced to ~4 Hz by [_uiCoalescer].
  // ---------------------------------------------------------------------------

  /// Latest streamed heart rate (bpm), or null when nothing has been measured.
  final ValueNotifier<int?> heartRateListenable = ValueNotifier<int?>(null);

  /// Battery percentage 0-100.
  final ValueNotifier<int?> batteryListenable = ValueNotifier<int?>(null);

  /// Live step/distance/calorie counters from fee0/0x0007.
  final ValueNotifier<BandMetrics> metricsListenable =
      ValueNotifier<BandMetrics>(const BandMetrics());

  /// Connection + authentication phase, for the status chip.
  final ValueNotifier<AuthState> authStateListenable =
      ValueNotifier<AuthState>(AuthState.notAuthenticated);

  /// True while an activity/SpO2 fetch is in flight.
  final ValueNotifier<bool> fetchingListenable = ValueNotifier<bool>(false);

  /// True while realtime HR streaming is armed.
  final ValueNotifier<bool> realtimeHrListenable = ValueNotifier<bool>(false);

  late final Coalescer _uiCoalescer =
      Coalescer(_emitNow, interval: const Duration(milliseconds: 250));

  /// Persisting metrics writes to disk; it must never run inside a BLE notify
  /// callback. Steps notify once per stride while walking.
  final Debouncer _metricsSaveDebouncer =
      Debouncer(delay: const Duration(seconds: 5));

  /// The activity store re-encodes its whole history on save.
  final Debouncer _storeSaveDebouncer =
      Debouncer(delay: const Duration(seconds: 10));

  /// Cached GATT service list for the current connection. Service discovery is
  /// a full round-trip to the band; the old code re-ran it inside nine separate
  /// helpers (`_syncTime`, `_setFitnessGoal`, `_subscribeToSteps`,
  /// `_writeConfig`, `_setUserInfo`, `_setupHeartRate`, `_readBattery`, …),
  /// which serialised connect-time setup behind ~9 redundant discoveries.
  List<BluetoothService>? _cachedServices;

  BLEManager(this._logger, this._storage) {
    _loadPersistedData();
  }

  /// Discover services once per connection and reuse the result.
  Future<List<BluetoothService>> _discoverServicesCached(
      {bool force = false}) async {
    if (_device == null || !_device!.isConnected) return const [];
    if (!force && _cachedServices != null) return _cachedServices!;
    final services = await _device!.discoverServices();
    _cachedServices = services;
    return services;
  }

  /// Find a characteristic whose UUID contains [fragment] inside the service
  /// whose UUID contains [serviceFragment], using the cached service list.
  Future<BluetoothCharacteristic?> _findChar(
      String serviceFragment, String fragment) async {
    final services = await _discoverServicesCached();
    for (final svc in services) {
      if (!svc.uuid.str.toLowerCase().contains(serviceFragment)) continue;
      for (final c in svc.characteristics) {
        if (c.uuid.str.toLowerCase().contains(fragment)) return c;
      }
    }
    return null;
  }

  BluetoothDevice? get device => _device;
  AuthState get authState => _authState;
  bool get isAuthenticating => _isAuthenticating;
  bool get isReconnecting => _isReconnecting;
  BandMetrics get metrics => _metrics;

  /// Whether a real metrics packet has arrived from the band this session.
  ///
  /// `_metrics` starts as `const BandMetrics()` — zeros — and nothing restores
  /// a previous value, so between launch and the first successful read the
  /// Activity screen showed "0.00 km" and "0 kcal" as though they were today's
  /// measurements. A zero the band never reported is a claim, not a default.
  bool get hasLiveMetrics => _hasLiveMetrics;
  bool _hasLiveMetrics = false;
  int? get batteryLevel => _batteryLevel;
  int? get heartRate => _heartRate;
  DateTime? get lastSyncTime => _lastSyncTime;
  bool get isFetchingActivity => _isFetchingActivity;

  // ---------------------------------------------------------------------------
  // Persistent data
  // ---------------------------------------------------------------------------

  Future<void> _loadPersistedData() async {
    _userWantsHrStreaming = await _storage.getWantsHrStreaming();
    _declineText = await _storage.getDeclineText();
    await activityStore.load();
    _lastSyncTime = activityStore.lastActivitySync;
    _emitChange();
  }

  // ---------------------------------------------------------------------------
  // Foreground Service helpers
  // ---------------------------------------------------------------------------

  static void _initForegroundTaskConfig() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'mi_band_ble',
        channelName: 'Mi Band Connection',
        channelDescription: 'Keeps your Mi Band connected in the background.',
        onlyAlertOnce: true,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(10000),
        // Come back by ourselves after a reboot or an app update, so a paired
        // band reconnects without the user having to open the app. The
        // supervisor still checks the persisted "wants connected" intent before
        // doing anything, so a user who explicitly disconnected stays
        // disconnected.
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
      ),
    );
  }

  Future<void> _startForegroundService() async {
    if (await FlutterForegroundTask.isRunningService) return;
    // Android 13+ needs POST_NOTIFICATIONS before the service can show its
    // persistent notification. Requesting it here (rather than at first launch)
    // means we ask at the moment the reason is obvious: a band just connected.
    await _backgroundPermissions.requestNotifications();
    _initForegroundTaskConfig();
    await FlutterForegroundTask.startService(
      serviceId: 1001,
      notificationTitle: 'Mi Band',
      notificationText: _foregroundStatusText(),
      callback: startCallback,
    );
  }

  Future<void> _stopForegroundService() async {
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
  }

  Future<void> _updateForegroundNotification(String text) async {
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.updateService(
        notificationTitle: 'Mi Band',
        notificationText: text,
      );
    }
  }

  /// Persistent-notification body: connection state + battery + last sync.
  ///
  /// This notification is the only thing the user sees while the app is in the
  /// background, so it has to answer "is it working?" without opening the app.
  String _foregroundStatusText() {
    final parts = <String>[_connectionPhase.label];
    final battery = _batteryLevel;
    if (battery != null) parts.add('$battery%');
    final sync = _lastSyncTime;
    if (sync != null) {
      final mins = DateTime.now().difference(sync).inMinutes;
      parts.add(mins < 1
          ? 'synced just now'
          : (mins < 60 ? 'synced ${mins}m ago' : 'synced ${mins ~/ 60}h ago'));
    }
    return parts.join(' · ');
  }

  Future<void> _refreshForegroundNotification() =>
      _updateForegroundNotification(_foregroundStatusText());

  // ---------------------------------------------------------------------------
  // Auto-connect on app startup
  // ---------------------------------------------------------------------------

  /// Call this once at app startup.
  ///
  /// Resumes supervision when a band is paired and the user has not explicitly
  /// disconnected — the supervisor then owns connecting, retrying with backoff,
  /// and reacting to the Bluetooth adapter. See `connection_supervisor.dart`.
  Future<void> tryAutoConnect() async {
    final savedId = await _storage.getLastDeviceId();
    if (savedId == null || savedId.isEmpty) {
      _logger.d("No saved device ID — skipping auto-connect.");
      return;
    }
    if (!await _storage.getWantsConnected()) {
      _logger.i("Auto-connect: user previously disconnected — staying idle.");
      return;
    }
    _logger.i("Auto-connect: supervising saved device $savedId.");
    await startSupervision();
  }

  // ---------------------------------------------------------------------------
  // Connection
  // ---------------------------------------------------------------------------

  Future<void> connect(BluetoothDevice target) async {
    if (_device?.remoteId == target.remoteId && isConnected) {
      // Re-subscribing to `connectionState` while connected replays the
      // `connected` value at once, which would run `_handleConnected` — and
      // the auth handshake — a second time on a link that already has one.
      _logger.i("Already connected to ${target.remoteId} — not reconnecting.");
      return;
    }
    _userDisconnected = false;
    _logger.i("Connecting to ${target.remoteId}...");
    _device = target;
    _cachedServices = null; // new connection ⇒ new GATT database
    _setPhase(ConnectionPhase.connecting);
    _emitImmediate(); // the user tapped Connect and is watching for feedback

    _connSubscription?.cancel();
    _reconnectTimer?.cancel();
    _isReconnecting = false;
    // Ignore the replayed `disconnected` that arrives before we have connected.
    //
    // `connectionState` is a stream with an initial value, and that value is
    // `disconnected` whenever the plugin has no cached state for the device —
    // i.e. on every first connect and after every real drop. So the listener
    // fired `_handleDisconnect()` in a microtask *before* `target.connect()`
    // had even been issued, which tore down state we were about to build and
    // re-armed the reconnect timer this method had just cancelled two lines
    // above. Every connection attempt therefore scheduled a competing one.
    //
    // A disconnect only means something once we have actually been connected.
    var everConnected = false;
    _connSubscription = target.connectionState.listen((state) {
      _logger.i("Connection state: $state");
      if (state == BluetoothConnectionState.disconnected) {
        if (!everConnected) {
          _logger.d("Ignoring replayed initial 'disconnected' state");
          return;
        }
        _handleDisconnect();
      } else if (state == BluetoothConnectionState.connected) {
        everConnected = true;
        _handleConnected();
      }
      _emitChange();
    });

    try {
      await target.connect(autoConnect: false);
    } catch (e) {
      _logger.e("Connect error: $e");
    }
  }

  void _handleDisconnect() {
    _isAuthenticating = false;
    _setAuthState(AuthState.notAuthenticated);
    _authChar = null;
    _stepsChar = null;
    _hrMeasureChar = null;
    _hrControlChar = null;
    _battChar = null;
    // The GATT database belongs to the connection — a reconnect must re-discover
    // rather than hand out stale characteristic handles.
    _cachedServices = null;
    // Same reasoning for the fetcher: its notify subscriptions are bound to
    // this connection's characteristics, so it has to be torn down here rather
    // than carried into the next one.
    _activityFetcher?.dispose();
    _activityFetcher = null;
    _fetcherDevice = null;
    _battSubscription?.cancel();
    _battSubscription = null;
    for (final sub in _initCharSubs) {
      sub.cancel();
    }
    _initCharSubs.clear();
    _charSubscription?.cancel();
    _stepsSubscription?.cancel();
    _hrSubscription?.cancel();
    _hrKeepAliveTimer?.cancel();
    _stopPeriodicSync();
    _stepsPollTimer?.cancel();
    _setRealtimeHrActive(false);
    _disposeChunked();
    // NOTE: _metrics is intentionally NOT reset — we keep the last known values
    // so the UI can still display historical data while disconnected.
    _setBatteryLevel(null);
    _setHeartRate(null);
    _logger.e("Device disconnected.");

    // Flush anything the debouncers were holding — the disconnect may be the
    // last event before the process is backgrounded.
    _flushPendingWrites();

    // Remember whether HR was streaming so the next successful auth can put it
    // back the way the user left it.
    if (!_userDisconnected && _userWantsConnected) {
      // Keep the foreground service alive while we are actively reconnecting:
      // stopping it here is what previously let Android reclaim the process
      // mid-backoff, so the band never came back until the app was reopened.
      _setPhase(ConnectionPhase.waitingToRetry);
      _updateForegroundNotification('Disconnected — reconnecting…');
      _scheduleReconnectWithBackoff();
    } else {
      _stopForegroundService();
      _setPhase(ConnectionPhase.idle);
    }
  }

  /// Persist anything the save debouncers still owe.
  void _flushPendingWrites() {
    if (_metricsSaveDebouncer.isPending) {
      _metricsSaveDebouncer.cancel();
      _persistMetrics();
    }
    if (_storeSaveDebouncer.isPending) {
      _storeSaveDebouncer.cancel();
      activityStore.save();
    }
  }

  void _persistMetrics() {
    _storage.saveMetrics(_metrics);
    final ts = _lastSyncTime;
    if (ts != null) _storage.saveLastSyncTime(ts);
  }

  void _setHeartRate(int? bpm) {
    _heartRate = bpm;
    heartRateListenable.value = bpm;
  }

  void _setBatteryLevel(int? level) {
    _batteryLevel = level;
    batteryListenable.value = level;
    // The background notification shows the battery, so keep it current.
    if (level != null) _refreshForegroundNotification();
  }

  void _setRealtimeHrActive(bool active) {
    _realtimeHrActive = active;
    realtimeHrListenable.value = active;
  }

  void _setFetchingActivity(bool fetching) {
    _isFetchingActivity = fetching;
    fetchingListenable.value = fetching;
  }

  Future<void> _handleConnected() async {
    _reconnectTimer?.cancel();
    _isReconnecting = false;
    _markPacket(); // the link is alive; start the liveness clock
    _logger.i("Connected successfully.");
    if (_device == null) return;

    // A successful link resets the backoff schedule, so the *next* unrelated
    // drop starts again at 1 s rather than inheriting a 60 s penalty.
    _backoff.reset();

    // Save MAC so we can auto-connect on next app launch
    await _storage.saveLastDeviceId(_device!.remoteId.str);

    // Start foreground service to keep process alive in background
    await _startForegroundService();

    try {
      // Record what we actually got, not what we asked for: notification
      // chunking is computed from the negotiated MTU, and a failed/partial
      // negotiation must produce more small frames rather than a truncated
      // notification (findings-17).
      final granted = await _device!.requestMtu(247);
      _mtu = granted > 0 ? granted : _mtu;
      alertManager.setMtu(_mtu);
      _logger.i("MTU negotiated: $_mtu (requested 247)");
    } catch (e) {
      _logger.e("MTU request failed: $e — keeping $_mtu");
      alertManager.setMtu(_mtu);
    }

    _logger.i("Discovering services...");
    final services = await _discoverServicesCached(force: true);

    // Standard Alert Notification Service NEW_ALERT (0x2A46). Mi Band 6 takes
    // incoming-call alerts here, not on the chunked fee0 channel — see
    // AmazfitBipTextNotificationStrategy (protocol-mb6.md §8.3, findings-17).
    final newAlert = await _findChar('1811', '2a46');
    alertManager.setNewAlertCharacteristic(newAlert);
    _logger.i(newAlert != null
        ? 'Found ANS NEW_ALERT characteristic (0x2A46) for call alerts'
        : 'ANS NEW_ALERT (0x2A46) not found — call alerts unavailable');

    BluetoothService? authService;
    for (var svc in services) {
      final uuid = svc.uuid.str.toLowerCase();
      _logger.d("SERVICE UUID: $uuid");

      // Discover Custom Alert Service (fee0)
      if (uuid.contains("fee0")) {
        for (var char in svc.characteristics) {
          final cu = char.uuid.str.toLowerCase();
          if (cu == "00000020-0000-3512-2118-0009af100700") {
            _alertChar = char;
            alertManager.setCharacteristic(_alertChar);
            _logger.i("Found Custom Alert Characteristic (0x0020)");
          }
          // Huami 2021 chunked transport (sign-key auth + encrypted data).
          if (cu.startsWith("00000016-")) _chunkedWriteChar = char;
          if (cu.startsWith("00000017-")) _chunkedNotifyChar = char;
        }
      }

      if (uuid.contains("fee1")) {
        _logger.i("FEE1 FOUND");
        authService = svc;
      }
    }

    if (authService == null) {
      _logger.e("FEE1 service not found.");
      return;
    }

    // The canonical Huami/Mi-Band auth characteristic is 0x0009
    // (00000009-0000-3512-2118-0009af100700). On-device captures (findings-05)
    // showed that authenticating on `fec1` only yields a non-standard, partial
    // auth — enough for battery/steps but NOT the protected 0x180D HR service or
    // activity-data responses. Prefer 0x0009; fall back to fec1 if absent.
    BluetoothCharacteristic? authChar0009;
    BluetoothCharacteristic? authCharFec1;
    for (var char in authService.characteristics) {
      final cuuid = char.uuid.str.toLowerCase();
      _logger.d("CHAR UUID: $cuuid");
      if (cuuid.startsWith("00000009-")) authChar0009 = char;
      if (cuuid.contains("fec1")) authCharFec1 = char;
    }
    _authChar = authChar0009 ?? authCharFec1;

    // This firmware requires the Huami 2021 sign-key (ECDH) auth over the
    // chunked transport (findings-06). Prefer it when 0x0016/0x0017 are present;
    // otherwise fall back to the legacy handshake.
    if (hasChunkedTransport) {
      _logger.i("Chunked transport (0x0016/0x0017) present — "
          "using Huami 2021 sign-key auth.");
      await start2021Auth();
      return;
    }

    if (_authChar == null) {
      _logger.e("No auth characteristic (0x0009 or fec1) found.");
      return;
    }

    _logger.i(authChar0009 != null
        ? "Using canonical Huami auth char 0x0009. Starting auth handshake..."
        : "Using fec1 auth char (0x0009 absent). Starting auth handshake...");

    // Proactively subscribe to status/init chars before auth success
    await _subscribeToMissingNotifications();

    await _startAuthHandshake();
  }

  // ---------------------------------------------------------------------------
  // Authentication — canonical Huami / Mi Band 6 handshake (Gadgetbridge
  // InitOperation). authFlags = AUTH_BYTE = 0x08; cryptFlags = 0x80 for MB6
  // (MiBand4Support override, inherited by MB5/6). See findings-06.
  //   → 01 08 <16-byte key>
  //   ← 10 01 01            (key accepted; high bits in status are tolerated)
  //   → 82 08 02 01 00      (request random; 0x80|0x02 because cryptFlags=0x80)
  //   ← 10 02 01 <16 rand>
  //   → 83 08 <AES-ECB(key, rand)>   (0x80|0x03)
  //   ← 10 03 01            (auth success)
  // ---------------------------------------------------------------------------

  static const int _authFlags = 0x08; // AUTH_BYTE
  static const int _cryptFlags = 0x80; // MiBand4/5/6

  Future<void> _startAuthHandshake() async {
    if (_isAuthenticating) return;
    if (_authChar == null || !_device!.isConnected) return;

    _isAuthenticating = true;
    _setAuthState(AuthState.authenticating);
    _emitChange();

    try {
      await _authChar!.setNotifyValue(true);
      _logger.d("Notifications enabled for FEC1.");

      _charSubscription?.cancel();
      _charSubscription = _authChar!.onValueReceived.listen((value) {
        if (value.isNotEmpty) _handleAuthResponse(value);
      });

      await Future.delayed(const Duration(milliseconds: 400));

      Uint8List? authKeyBytes = await _storage.getAuthKeyBytes();
      if (authKeyBytes == null || authKeyBytes.length != 16) {
        _logger.e("Auth key missing or invalid! Expected 16 bytes.");
        _failAuth();
        return;
      }

      // The key itself is never logged, at any level.
      //
      // It is the credential that proves ownership of the band: anyone holding
      // it, in Bluetooth range, can talk to the device. It was being written in
      // full hex to the in-app log buffer and to logcat, where any other app
      // with READ_LOGS, an adb capture, or a bug report attached to an issue
      // would carry it. `debug` level was not protection either — the buffer is
      // shown in the Debug Console and is what users are asked to paste.
      //
      // The length alone is enough to diagnose a malformed key.
      _logger.d("Auth key loaded: ${authKeyBytes.length} bytes");

      _authTimeoutTimer?.cancel();
      _authTimeoutTimer = Timer(const Duration(seconds: 20), () {
        _logger.e("Auth timeout");
        _isAuthenticating = false;
        _setAuthState(AuthState.failed);
        _emitChange();
      });

      // Mi Band 6 is an already-paired device with cryptFlags = 0x80, so
      // Gadgetbridge sets needsAuth=false and SKIPS the send-key step — it goes
      // straight to requesting the random number. We do the same: re-sending the
      // key (01 08 …) to a paired band poisons the handshake (ends in status
      // 0x07). authFlags = 0x08; the request is 5 bytes because cryptFlags≠0.
      _logger.i("Auth: requesting random number "
          "[0x${(_cryptFlags | 0x02).toRadixString(16)}, 0x08, 02, 01, 00]");
      await safeWrite([_cryptFlags | 0x02, _authFlags, 0x02, 0x01, 0x00]);
    } catch (e) {
      _logger.e("Auth Handshake Error: $e");
      _isAuthenticating = false;
      _setAuthState(AuthState.failed);
      _emitChange();
    }
  }

  void _handleAuthResponse(List<int> response) async {
    _markPacket();
    _logger.d(
      "Received raw bytes: ${response.map((e) => e.toRadixString(16).padLeft(2, '0')).join(' ')}",
    );

    // Canonical Huami response framing: [0x10, cmd, status, ...payload]. The
    // command/status bytes can carry the cryptFlags high bit (0x80), so mask the
    // low nibble before comparing (matches Gadgetbridge `value[1] & 0x0f`).
    if (response.length < 3 || response[0] != 0x10) {
      if (response.every((b) => b == 0xFF)) {
        _authTimeoutTimer?.cancel();
        _logger.e("Auth: band rejected with 0xFF");
        _failAuth();
      } else {
        _logger.d("Auth: ignoring non-response frame");
      }
      return;
    }

    final cmd = response[1] & 0x0f;
    final status = response[2] & 0x0f;
    const success = 0x01;
    const fail = 0x04;

    if (cmd == 0x01) {
      // Send-key response.
      if (status == success) {
        _logger.i("Auth Step 1 OK: requesting random number "
            "[0x${(_cryptFlags | 0x02).toRadixString(16)}, 0x08, 02, 01, 00]");
        // cryptFlags (0x80) is non-zero on MB6, so the request is 5 bytes.
        await safeWrite([_cryptFlags | 0x02, _authFlags, 0x02, 0x01, 0x00]);
      } else {
        _authTimeoutTimer?.cancel();
        _logger.e("Auth Step 1 FAILED: band rejected key "
            "(status=0x${response[2].toRadixString(16)})");
        _failAuth();
      }
    } else if (cmd == 0x02) {
      // Random-number response: [10, 82, 01, <16 random bytes>].
      if (status == success && response.length >= 19) {
        _logger.i("Auth Step 2 OK: random received, encrypting 16 bytes...");
        await _encryptAndSendStep3(response.sublist(3, 19));
      } else {
        _authTimeoutTimer?.cancel();
        _logger.e("Auth Step 2 FAILED (status=0x${response[2].toRadixString(16)}, "
            "len=${response.length})");
        _failAuth();
      }
    } else if (cmd == 0x03) {
      // Encrypted-number response → final verdict.
      _authTimeoutTimer?.cancel();
      if (status == success) {
        _logger.i("Authentication SUCCESS! (canonical Huami auth)");
        _isAuthenticating = false;
        _setAuthState(AuthState.authenticated);
        _emitChange();
        _onAuthSuccess();
      } else if (status == fail) {
        _logger.e("Auth Step 3 FAILED: encryption mismatch — wrong key");
        _failAuth();
      } else {
        _logger.e("Auth Step 3 unexpected status "
            "0x${response[2].toRadixString(16)}");
        _failAuth();
      }
    } else {
      _logger.d("Auth: unhandled response cmd=0x${response[1].toRadixString(16)}");
    }
  }

  Future<void> _encryptAndSendStep3(List<int> challenge) async {
    Uint8List? keyBytes = await _storage.getAuthKeyBytes();
    if (keyBytes == null || keyBytes.length != 16) {
      _logger.e("Auth key missing or invalid during encryption.");
      _failAuth();
      return;
    }
    try {
      final encrypted = BLEEncryption.encryptAESECB(
        keyBytes,
        Uint8List.fromList(challenge),
      );
      _logger.d(
        "Encrypted (${encrypted.length} bytes): "
        "${encrypted.map((e) => e.toRadixString(16).padLeft(2, '0')).join(' ')}",
      );
      // 0x03 | cryptFlags(0x80) = 0x83, authFlags = 0x08.
      _logger.i("Auth Step 3: Sending [0x83, 0x08] + encrypted bytes...");
      await safeWrite([_cryptFlags | 0x03, _authFlags, ...encrypted]);
    } catch (e) {
      _logger.e("Encryption failed: $e");
      _failAuth();
    }
  }

  void _onAuthSuccess() async {
    _backoff.reset();
    _markPacket();
    _refreshForegroundNotification();

    // Step 1: Sync time (critical for some bands to enable other features)
    await _syncTime();
    await Future.delayed(const Duration(milliseconds: 300));

    // Step 2: Re-apply the user's settings. The band loses some of these across
    // a reset, and a reconnect must restore what the user configured —
    // Gadgetbridge likewise re-sends on every connect rather than only at
    // pairing time. This replaces the previous hard-coded writes (24 h time,
    // date display, a fixed 10 000-step goal) which silently overwrote whatever
    // the user had chosen.
    // NOT called: `_setUserInfo` writes an invented profile. See its doc.
    // await _setUserInfo();
    await bandConfig.applyAll(reason: 'post-auth');

    // Step 3: Subscriptions
    await _subscribeToSteps();
    await _subscribeDeviceEvents(); // 0x0010 — post-auth only, §12
    await _readBattery();
    // Realtime HR over the standard 0x180D service (0x2A37/0x2A39) with the
    // required ~14 s keep-alive ping. See protocol-mb6.md §3.
    // Re-armed only if the user had it on — a reconnect must restore the
    // previous state, not silently switch streaming back on.
    if (_userWantsHrStreaming) {
      await startRealtimeHeartRate();
    } else {
      _logger.i('HR: streaming stays off (user had it disabled).');
    }

    await Future.delayed(const Duration(seconds: 2));

    // Step 4: Initial fetch, then keep syncing.
    _fetchActivityData();
    _startPeriodicSync();
  }

  // ── Periodic sync ─────────────────────────────────────────────────────────

  Timer? _syncTimer;

  /// How often to pull new data off the band while connected.
  ///
  /// The band records heart rate, stress and activity into its own memory; none
  /// of it reaches the app until we fetch. Ten minutes keeps the screens close
  /// to live without hammering the link — a fetch is a multi-second transfer.
  static const Duration periodicSyncInterval = Duration(minutes: 10);

  /// Hard backstop on rounds in one crawl. Not the real limit — [deepFetchBudget]
  /// and [periodicFetchBudget] are — this only stops a runaway loop.
  ///
  /// It used to be 12, which was the real limit and far too low: each round
  /// advances only as far as the band's next gap, sometimes ten minutes, so a
  /// sync could not even cross the re-fetch overlap. See the comment on
  /// `since` in `_fetchActivityData`.
  static const int maxFetchRounds = 600;

  /// Wall-clock budget for a manual "Sync now".
  ///
  /// Kept short because someone is watching a spinner. It does not need to
  /// finish a multi-day backfill in one press: the recent window is fetched
  /// first, so the current day is already correct when this starts, and the
  /// watermark advances so each subsequent sync resumes rather than restarts.
  static const Duration deepFetchBudget = Duration(seconds: 90);

  /// Wall-clock budget for the automatic 10-minute sync.
  ///
  /// Short, because it runs unattended and holds the radio. When caught up a
  /// sync needs one or two rounds; when behind it chips away and resumes from
  /// the advanced watermark next time.
  static const Duration periodicFetchBudget = Duration(seconds: 45);

  /// Whether the band's own stress stream is trusted enough to store.
  ///
  /// False until probe P1 settles what fetch types 0x13/0x12 actually return on
  /// this firmware. Everything the app stored under the previous assumption —
  /// 26 863 readings — decoded as activity bytes rather than stress
  /// (findings-23). Flipping this to true is the whole of Phase 3: the parsers,
  /// the store, the watermarks and the analysis are all in place behind it.
  static const bool kStressFetchVerified = false;

  /// True while a sync is running, so the UI can show it and callers can avoid
  /// stacking fetches.
  bool get isSyncing => _isFetchingActivity;

  /// Starts (or restarts) the periodic sync.
  ///
  /// **This is the fix for "the data only updates when I toggle something".**
  /// `_fetchActivityData` used to be called from exactly one place — right after
  /// authentication — so band-recorded data (periodic heart rate, all-day
  /// stress, activity history) only ever arrived on a *fresh connection*.
  /// Turning live heart-rate monitoring on and off happened to force a
  /// reconnect, which is why data appeared to depend on that toggle rather than
  /// on time passing.
  void _startPeriodicSync() {
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(periodicSyncInterval, (_) {
      if (!canConfigure) return; // not connected/authenticated
      if (_isFetchingActivity) return; // one at a time
      _logger.i('Sync: periodic refresh');
      _fetchActivityData();
    });
  }

  void _stopPeriodicSync() {
    _syncTimer?.cancel();
    _syncTimer = null;
  }

  /// Pull new data from the band now (pull-to-refresh, or a Sync button).
  ///
  /// Safe to call at any time: it no-ops when the band is not ready and when a
  /// fetch is already running.
  Future<void> syncNow() async {
    if (!canConfigure) {
      _logger.i('Sync: skipped — band not connected/authenticated');
      return;
    }
    if (_isFetchingActivity) {
      _logger.d('Sync: already in progress');
      return;
    }
    // A manual sync deliberately re-requests a wide window. It is the user's
    // way to recover a hole — the band keeps roughly a week of history, so a
    // gap left by a phone that was off or disconnected can still be pulled back.
    _logger.i('Sync: manual refresh requested (deep backfill)');
    await _fetchActivityData(deep: true);
  }

  Future<void> _syncTime() async {
    if (_device == null || !_device!.isConnected) return;

    // Find the current time characteristic (0x2A2B in fee0)
    BluetoothCharacteristic? timeChar;
    try {
      timeChar = await _findChar('fee0', '2a2b');
    } catch (e) {
      _logger.e("TimeSync discovery failed: $e");
    }

    if (timeChar == null) {
      _logger.d("TimeSync: characteristic 0x2A2B not found, skipping.");
      return;
    }

    final now = DateTime.now();
    final dayOfWeek = now.weekday == 7 ? 7 : now.weekday; // matches GB logic

    // Gadgetbridge format for Huami (11 bytes total)
    // year_lo, year_hi, month, day, hour, minute, second, dayOfWeek, fractions256, adjustReason, tzQuarters
    final tzOffsetMinutes = now.timeZoneOffset.inMinutes;
    final tzQuarters = (tzOffsetMinutes / 15).floor();

    final cmd = [
      now.year & 0xFF,
      (now.year >> 8) & 0xFF,
      now.month,
      now.day,
      now.hour,
      now.minute,
      now.second,
      dayOfWeek,
      0x00, // fractions256
      0x00, // adjust reason
      tzQuarters & 0xFF,
    ];

    try {
      _logger.i(
          "TimeSync: syncing band clock to $now (0x2A2B) with ${cmd.length} bytes");
      await timeChar.write(cmd, withoutResponse: false);
    } catch (e) {
      _logger.e("TimeSync failed: $e");
    }
  }

  // ── Steps polling ─────────────────────────────────────────────────────────

  Timer? _stepsPollTimer;

  /// How often to re-read the live step counter.
  ///
  /// The band only *notifies* fee0/0x0007 when the count changes, so a single
  /// dropped notification leaves the displayed step count frozen until the next
  /// change — or until the app reconnects. That is what "steps are not syncing"
  /// looks like from the outside: the number sticks while the band's own screen
  /// climbs. Re-reading on a timer makes a missed notification self-heal within
  /// one interval instead of persisting for hours.
  static const Duration stepsPollInterval = Duration(minutes: 2);

  void _startStepsPolling() {
    _stepsPollTimer?.cancel();
    _stepsPollTimer = Timer.periodic(stepsPollInterval, (_) async {
      final ch = _stepsChar;
      if (ch == null || !isConnected || !ch.properties.read) return;
      try {
        final raw = await ch.read();
        // Logged at info level: this is the value to compare against the band's
        // own display when a step count is disputed.
        _logger.i('Steps poll: raw = ${_hexStr(raw)}');
        _applyStepsPacket(raw);
      } catch (e) {
        _logger.d('Steps poll failed: $e');
      }
    });
  }

  /// Fetches band data. [deep] forces a wide (7-day) window instead of the
  /// incremental one, so an existing hole can be backfilled.
  Future<void> _fetchActivityData({bool deep = false}) async {
    if (_device == null || !_device!.isConnected) return;

    _setFetchingActivity(true);
    _emitChange();

    try {
      // One fetcher per connection, not one per fetch.
      //
      // `ActivityFetcher.init()` subscribes to `onValueReceived` on both the
      // control and data characteristics. A fresh fetcher was built on every
      // call and the previous one was never disposed, so each sync left another
      // live listener on the same characteristics — and every one of them
      // handles every notification.
      //
      // Two listeners means the metadata frame is processed twice, so `0x02`
      // (begin transfer) is written twice, and the band answers `10 02 04` —
      // error — instead of streaming. Nothing is fetched at all. Observed on
      // 2026-08-13: the band offered 2 910 samples and the app stored none,
      // with every `CTRL notified:` line in the log appearing in pairs.
      //
      // The leak has always been here, but it was harmless while
      // `_fetchActivityData` ran once per connection. Adding the 10-minute
      // periodic sync (commit 5fa3993) turned it into one extra listener every
      // ten minutes, which is why step, sleep and HR history all stopped
      // updating a few hours into a session.
      if (_activityFetcher == null || !identical(_fetcherDevice, _device)) {
        _activityFetcher?.dispose();
        _activityFetcher = ActivityFetcher(_logger, _device!);
        _fetcherDevice = _device;
        final ok = await _activityFetcher!.init();
        if (!ok) {
          _logger.e('Activity fetch: init failed');
          _activityFetcher?.dispose();
          _activityFetcher = null;
          _fetcherDevice = null;
          return;
        }
      }

      // Choose the fetch window: backfill a week until we have a few days of
      // history stored, then fetch incrementally (with a 6 h overlap so gaps
      // around the boundary are re-pulled). Samples are de-duplicated by
      // timestamp in the store, so overlap is harmless — but only because
      // `fetchRawData` truncates its start to the minute. It did not, and the
      // invented seconds made every overlapping fetch store a second copy of
      // each minute.
      // The watermark is "how far we have synced", so it can never sensibly sit
      // behind the newest sample we already hold. It can end up there — a stale
      // value persisted before the monotonic setter landed, or a store restored
      // from backup — and then the app asks for a window it has already got,
      // gets the same batch back, fails to advance, and re-fetches it forever.
      // Observed tonight: watermark 08-08 23:26 with samples stored through
      // 08-12 20:56, re-pulling the same 361 samples every ten minutes.
      final newestStored = activityStore.samples.isNotEmpty
          ? activityStore.samples.last.timestamp
          : null;
      if (newestStored != null) activityStore.updateActivitySync(newestStored);

      final lastSync = activityStore.lastActivitySync;
      final now = DateTime.now();
      final earliest = activityStore.samples.isNotEmpty
          ? activityStore.samples.first.timestamp
          : now;
      final haveDeepHistory =
          earliest.isBefore(now.subtract(const Duration(days: 3)));
      // Overlap is small on purpose.
      //
      // It used to be six hours, which deadlocked the sync completely. Each
      // round of the loop below advances only as far as the band's next gap —
      // often ten minutes — so with a twelve-round cap the fetch spent its
      // whole budget re-crawling ground it already had and finished exactly
      // where it started. Net progress per sync: zero. The user's data sat
      // frozen for five days while every sync appeared to be doing work.
      //
      // Samples de-duplicate by minute, so overlap costs nothing but rounds,
      // and rounds are the scarce resource. Ten minutes is enough to re-pull a
      // boundary minute that arrived mid-write.
      //
      // A manual sync reaches back a day rather than a week. Going back seven
      // days made sense when one fetch could not cross a gap and re-requesting
      // was the only way to fill one; now the crawl below walks gaps by itself,
      // so a week-long start just means re-walking a week of history the store
      // already holds, at a couple of seconds a round.
      final DateTime since;
      if (lastSync != null && haveDeepHistory) {
        since = deep
            ? lastSync.subtract(const Duration(hours: 24))
            : lastSync.subtract(const Duration(minutes: 10));
      } else {
        since = now.subtract(const Duration(days: 7));
      }

      // One activity fetch yields steps, sleep AND heart-rate history — HR is
      // embedded at byte 3 of each 8-byte sample (see protocol-mb6.md §5).
      //
      // Fetch repeatedly until the band runs out, not once.
      //
      // One request does NOT return everything from `since` to now. The band
      // serves a contiguous run and stops at the first discontinuity in its
      // ring buffer — a stretch where it was charging, off the wrist, or the
      // log wrapped. Asking from 2026-08-06 returned 2 902 samples ending
      // 08-08 23:26 and stopped, while a request from 08-13 03:40 returned 361
      // ending 09:40 and stopped, on the same band, minutes apart.
      //
      // A single round therefore makes a gap permanent: the watermark advances
      // only to the end of the run, the next sync asks `watermark - 6 h`, lands
      // in the same run, gets the same batch, and the app can never climb past
      // the hole. That is why steps, sleep and heart-rate history all froze at
      // 09:40 while the band's own step counter kept climbing. Gadgetbridge
      // re-issues the request from the last received timestamp for exactly this
      // reason (`AbstractRepeatingFetchOperation`).
      // Show today before spending the budget on last week.
      //
      // The crawl below walks forward from the watermark, so when it is days
      // behind, every round is spent on old data and the *current* day never
      // reaches the screen — the user opens the app, sees a stale step count,
      // and reasonably concludes it is broken.
      //
      // So when we are a long way behind, grab the recent window first. This
      // deliberately does NOT touch the watermark: `updateActivitySync` is
      // monotonic, so moving it to now would strand everything in between and
      // the backfill point would be lost for good. `addSamples` never touches
      // the watermark, which is what makes this safe.
      //
      // This applies to a manual sync too. "Sync now" that spends its whole
      // budget on a five-day-old gap, and leaves today's step count stale, is
      // the opposite of what the button appears to promise.
      if (lastSync != null && haveDeepHistory) {
        final behind = now.difference(lastSync);
        if (behind > const Duration(hours: 12)) {
          _logger.i('Sync: watermark is ${behind.inHours} h behind — fetching '
              'the recent window first so today is not hidden by the backfill');
          await _crawlActivity(
            from: now.subtract(const Duration(hours: 6)),
            budget: const Duration(seconds: 20),
            advanceWatermark: false,
            label: 'recent',
          );
        }
      }

      // Then the backfill, from the watermark forward.
      await _crawlActivity(
        from: since,
        budget: deep ? deepFetchBudget : periodicFetchBudget,
        advanceWatermark: true,
        label: deep ? 'deep' : 'incremental',
      );

      // Stress measured by the band itself (findings-20 documented the fetch
      // types; findings-23 established that what comes back is not stress).
      //
      // The fetch still runs, and what it returns is still logged, because that
      // log is the diagnostic probe P1 needs. Nothing is stored while
      // [kStressFetchVerified] is false — every reading the app ever kept from
      // this path decoded as activity bytes, and a plausible-looking wrong
      // number is worse than no number at all. The Stress screen falls back to
      // the heart-rate estimate and says so.
      _logger.i('Fetching stress history since $since');
      final stressAuto = await _activityFetcher!.fetchStressAuto(since);
      final stressManual = await _activityFetcher!.fetchStressManual(since);
      final stress = [...stressAuto, ...stressManual];
      if (!kStressFetchVerified) {
        _logger.i('Stress fetch: ${stressAuto.length} all-day + '
            '${stressManual.length} manual parsed, NOT STORED — the band\'s '
            'stress stream is unverified on this firmware (findings-23, probe P1)');
      } else if (stress.isNotEmpty) {
        activityStore.addStressReadings(stress);
        _logger.i('Stress fetch: ${stressAuto.length} all-day + '
            '${stressManual.length} manual readings');
      } else {
        _logger.i('Stress fetch: no data '
            '(is all-day stress enabled in Band settings?)');
      }

      _logger.i('Fetching SPO2 History since $since');
      final spo2 = await _activityFetcher!.fetchSpo2(since);
      if (spo2.isNotEmpty) {
        activityStore.addSpo2Readings(spo2);
        activityStore.updateSpo2Sync(
            spo2.map((r) => r.timestamp).reduce((a, b) => a.isAfter(b) ? a : b));
        _logger.i('SPO2 fetch: got ${spo2.length} readings');
      } else {
        _logger.i('SPO2 fetch: no new data');
      }

      // Persist
      await activityStore.save();
    } catch (e) {
      _logger.e('Activity fetch error: $e');
    } finally {
      // Keep the user-visible "last sync" in step with the real watermark.
      _lastSyncTime = activityStore.lastActivitySync;
      _setFetchingActivity(false);
      _emitChange();
    }
  }

  /// Walks the band's activity log forward from [from], one contiguous run at a
  /// time, until it reaches the present, the band runs dry, or [budget] is
  /// spent. Returns how many samples were stored.
  ///
  /// The band does not answer "everything since X" in one go — it serves a
  /// contiguous run and stops at the first discontinuity in its ring buffer (a
  /// stretch where it was charging, off the wrist, or the log wrapped). So the
  /// only way across a gap is to ask again from just past it, which is what
  /// Gadgetbridge's `AbstractRepeatingFetchOperation` does too.
  ///
  /// [advanceWatermark] is false for the "show me today first" pass, which
  /// fetches recent data out of order. The watermark is monotonic, so moving it
  /// forward there would strand every sample in between.
  Future<int> _crawlActivity({
    required DateTime from,
    required Duration budget,
    required bool advanceWatermark,
    required String label,
  }) async {
    final deadline = DateTime.now().add(budget);
    var cursor = from;
    var stored = 0;
    var rounds = 0;

    while (rounds < maxFetchRounds) {
      if (DateTime.now().isAfter(deadline)) {
        _logger.i('Activity fetch [$label]: budget spent after $rounds rounds '
            '($stored samples). Watermark has advanced, so the next sync picks '
            'up from ${cursor.toIso8601String()} rather than starting over.');
        break;
      }
      if (!isConnected) {
        _logger.i('Activity fetch [$label]: band went away mid-crawl after '
            '$rounds rounds — stopping cleanly');
        break;
      }
      rounds++;

      final samples = await _activityFetcher!.fetchActivityData(cursor);
      if (samples.isEmpty) {
        _logger.i(rounds == 1
            ? 'Activity fetch [$label]: no new samples'
            : 'Activity fetch [$label]: band has nothing beyond $cursor '
                '($rounds rounds, $stored samples)');
        break;
      }

      activityStore.addSamples(samples);
      stored += samples.length;

      // Watermark = the newest sample actually received, never wall-clock now.
      //
      // `now` silently loses data: the next fetch asks from the watermark, so a
      // disconnection longer than the overlap would move it past a window the
      // band still held, and that window would never be requested again.
      // Observed 2026-08-10: samples ran 1/min to 06:29 then stopped dead until
      // 17:00 — a 10.5-hour hole in a night the band had recorded fine.
      final newest = samples
          .map((s) => s.timestamp)
          .reduce((a, b) => a.isAfter(b) ? a : b);
      if (advanceWatermark) activityStore.updateActivitySync(newest);

      final hrReadings = ActivityFetcher.heartRatesFromSamples(samples);
      if (hrReadings.isNotEmpty) {
        activityStore.addHeartRateReadings(hrReadings);
        if (advanceWatermark) {
          activityStore.updateHrSync(hrReadings
              .map((r) => r.timestamp)
              .reduce((a, b) => a.isAfter(b) ? a : b));
        }
      }

      // Log per round only while crawling; a caught-up sync is one round and
      // would otherwise spam the log every ten minutes.
      if (rounds > 1 || samples.length > 60) {
        _logger.i('Activity fetch [$label] round $rounds: ${samples.length} '
            'samples, newest ${newest.toIso8601String()}');
      }

      // Reached the present — nothing newer can exist.
      if (newest.isAfter(DateTime.now().subtract(const Duration(minutes: 2)))) {
        _logger.i('Activity fetch [$label]: caught up to now '
            '($rounds rounds, $stored samples)');
        break;
      }

      // Step over the gap. Without the +1 minute the band hands back the same
      // run and the loop spins on the spot.
      final next = newest.add(const Duration(minutes: 1));
      if (!next.isAfter(cursor)) {
        _logger.e('Activity fetch [$label]: cursor failed to advance past '
            '$cursor — stopping to avoid a loop');
        break;
      }
      cursor = next;
    }

    if (rounds >= maxFetchRounds) {
      _logger.e('Activity fetch [$label]: hit the $maxFetchRounds-round '
          'backstop. That should be unreachable within the time budget — '
          'the band may be returning one sample at a time.');
    }
    return stored;
  }

  // ---------------------------------------------------------------------------
  // Real-time steps  (fee0 / 0x0007)
  // ---------------------------------------------------------------------------

  Future<void> _subscribeToSteps() async {
    if (_device == null || !_device!.isConnected) return;

    try {
      _stepsChar = await _findChar('fee0', '0007');
      if (_stepsChar == null) {
        _logger.e("Steps: 0x0007 not found in fee0.");
        return;
      }

      _logger.i("Steps: subscribing to 0x0007 "
          "(read=${_stepsChar!.properties.read} "
          "notify=${_stepsChar!.properties.notify})...");

      // Read the current value first — the notify only fires when the count
      // changes (i.e. while walking), so without an initial read the UI stays
      // empty when the user is stationary.
      if (_stepsChar!.properties.read) {
        try {
          final initial = await _stepsChar!.read();
          _logger.i("Steps: initial read raw = ${_hexStr(initial)}");
          _applyStepsPacket(initial);
        } catch (e) {
          _logger.e("Steps: initial read failed: $e");
        }
      }

      await _stepsChar!.setNotifyValue(true);
      _stepsSubscription?.cancel();
      _stepsSubscription = _stepsChar!.onValueReceived.listen((data) {
        _logger.d("Steps notify raw = ${_hexStr(data)}");
        _applyStepsPacket(data);
      });
      _startStepsPolling();
    } catch (e) {
      _logger.e("Steps subscription error: $e");
    }
  }

  void _applyStepsPacket(List<int> data) {
    _markPacket();
    final parsed = BandMetrics.fromStepsPacket(data);
    if (parsed == null) {
      _logger.d("Steps: packet not parseable (${data.length} B)");
      return;
    }
    _metrics = parsed;
    _hasLiveMetrics = true;
    metricsListenable.value = parsed;
    // Deliberately does NOT touch `_lastSyncTime` — see its declaration.
    _logger.i("Steps: ${parsed.steps} steps, ${parsed.distanceMeters} m, "
        "${parsed.calories} kcal");
    // Persisting is deferred: this runs inside a BLE notify callback that fires
    // repeatedly while the user is walking, and saveMetrics touches disk.
    _metricsSaveDebouncer(_persistMetrics);
    _emitChange();
  }

  // ---------------------------------------------------------------------------
  // Missing Notifications from Gadgetbridge Phase2/3
  // ---------------------------------------------------------------------------

  /// Subscribes to `fee0/0x0010` device events. Post-auth only — see §12.
  Future<void> _subscribeDeviceEvents() async {
    if (_device == null || !_device!.isConnected) return;
    try {
      final services = await _discoverServicesCached();
      for (final svc in services) {
        if (!svc.uuid.str.toLowerCase().contains('fee0')) continue;
        for (final char in svc.characteristics) {
          if (!char.uuid.str.toLowerCase().contains('0010')) continue;
          await char.setNotifyValue(true);
          _initCharSubs.add(char.onValueReceived.listen(_onDeviceEvent));
          _logger.i('Device events: subscribed to 0x0010 (post-auth)');
          return;
        }
      }
      _logger.e('Device events: 0x0010 not found under fee0');
    } catch (e) {
      _logger.e('Device events: subscribe failed: $e');
    }
  }

  Future<void> _subscribeToMissingNotifications() async {
    if (_device == null || !_device!.isConnected) return;
    try {
      final services = await _discoverServicesCached();
      for (final svc in services) {
        if (svc.uuid.str.toLowerCase().contains('fee0')) {
          for (final char in svc.characteristics) {
            final cu = char.uuid.str.toLowerCase();
            // 0x0003 (config) and 0x000F (notifs) before auth, as before.
            // 0x0010 (device events) is subscribed in [_subscribeDeviceEvents]
            // *after* auth: GB only enables its CCCD in
            // enableFurtherNotifications on AUTH_SUCCESS
            // (HuamiSupport.java:549, InitOperation2021.java:167), and the
            // band was not delivering events when it was armed early.
            if (cu.contains('0003') || cu.contains('000f')) {
              _logger.i("Subscribing to init characteristic $cu...");
              await char.setNotifyValue(true);
              if (cu.contains('0010')) {
                // Device events — the band's buttons and its own sleep/wear
                // determinations. Dispatched, not just logged. §12.
                _initCharSubs.add(char.onValueReceived.listen(_onDeviceEvent));
              } else {
                _initCharSubs.add(char.onValueReceived.listen((data) {
                  _logger.d(
                      "Init Char $cu data: ${data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}");
                }));
              }
            }
          }
        }
      }
    } catch (e) {
      _logger.e("Init chars subscription failed: $e");
    }
  }

  /// Handles one frame from `fee0/0x0010` — protocol-mb6.md §12.
  ///
  /// The mapping of each event to a phone action is the table in §12; the
  /// codes and payload offsets are Gadgetbridge's `handleDeviceEvent`. Anything
  /// this app does not act on is still logged in full, so an unexpected code
  /// shows up in the Debug Console rather than vanishing.
  Future<void> _onDeviceEvent(List<int> data) async {
    final e = BandEvent.parse(data);
    if (e == null) return;
    _markPacket();
    lastBandEvent.value = e;
    _logger.i('Band event: ${e.kind.name} '
        '[${data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}]');

    switch (e.kind) {
      case BandEventKind.fellAsleep:
      case BandEventKind.wokeUp:
      case BandEventKind.startNonWear:
        // Evidence for P12.3, not (yet) a driver of session detection.
        await bandEvents.add(e);
        break;

      case BandEventKind.callReject:
        // §12.1 — GB: GBDeviceEventCallControl.REJECT → TelecomManager.endCall()
        final ok = await callControl.endCall();
        _logger.i(ok ? 'Call declined from the band' : 'Band asked to decline the call but the phone refused (permission?)');
        if (ok) await _declineWithTextIfEnabled();
        break;

      case BandEventKind.callIgnore:
        // §12.1 — GB: CallControl.IGNORE → mute
        final ok = await callControl.silenceRinger();
        _logger.i(ok ? 'Ringer silenced from the band' : 'Could not silence the ringer');
        break;

      case BandEventKind.findPhoneStart:
        // §12.2 — ack exactly as GB does, then ring.
        await _writeConfig(kFindPhoneAck, 'find-phone ack');
        _findPhoneActive = true;
        await callControl.ringPhone();
        break;

      case BandEventKind.findPhoneStop:
        if (_findPhoneActive) {
          _findPhoneActive = false;
          await callControl.stopRinging();
        }
        break;

      case BandEventKind.silentMode:
        // §12.3 — toggling phone DND needs Notification Policy access, which
        // this app does not request. Logged only.
        _logger.i('Band silent mode: ${e.silentModeOn == true ? 'on' : 'off'} (not applied to phone)');
        break;

      case BandEventKind.mtuRequest:
        _logger.i('Band requests MTU ${e.mtu}');
        break;

      case BandEventKind.workoutStarting:
        _logger.i('Band workout starting: type=${e.workoutType} gps=${e.workoutNeedsGps}');
        break;

      case BandEventKind.musicControl:
        _logger.i('Band music control ${e.musicAction} (not wired)');
        break;

      case BandEventKind.buttonPressed:
      case BandEventKind.buttonPressedLong:
      case BandEventKind.stepsGoalReached:
      case BandEventKind.alarmToggled:
      case BandEventKind.alarmChanged:
      case BandEventKind.tick30Min:
        // Known, informational, nothing to do on the phone.
        break;

      case BandEventKind.unknown:
        _logger.e('Band event: undocumented code 0x${data[0].toRadixString(16)} — '
            'record it in protocol-mb6.md §12 before acting on it');
        break;
    }
  }

  /// §13.3 — phone-side decline-with-text. Needs the caller's number, which the
  /// notification relay records when the dialer's incoming-call notification
  /// carries one; if it did not, nothing is sent and the log says why.
  Future<void> _declineWithTextIfEnabled() async {
    final text = _declineText;
    if (text == null || text.trim().isEmpty) return;
    final number = lastIncomingCallNumber;
    if (number == null || number.isEmpty) {
      _logger.i('Decline-with-text: enabled, but no caller number was available');
      return;
    }
    final ok = await callControl.sendSms(number, text);
    _logger.i(ok ? 'Decline-with-text sent' : 'Decline-with-text failed (SEND_SMS?)');
  }

  Future<void> _writeConfig(List<int> cmd, String label) async {
    if (_device == null || !_device!.isConnected) return;
    try {
      final configChar = await _findChar('fee0', '0003');
      if (configChar != null) {
        // fee0/0x0003 on Mi Band 6 only supports Write-Without-Response; using
        // write-with-response throws "WRITE property not supported" (captured
        // on-device, findings-05). Pick the type the characteristic advertises.
        final useNoResponse = !configChar.properties.write &&
            configChar.properties.writeWithoutResponse;
        _logger.i("Setting $label via 0003 "
            "(withoutResponse=$useNoResponse)...");
        await configChar.write(cmd, withoutResponse: useNoResponse);
      }
    } catch (e) {
      _logger.e("Failed to set $label: $e");
    }
  }

  // ---------------------------------------------------------------------------
  // Set User Info (0x4f to 0x0008)
  // ---------------------------------------------------------------------------

  /// Writes a user profile to `fee0/0x0008`. **Not called.**
  ///
  /// Every value in it is invented: male, born 1990-01-01, 175 cm, 70 kg,
  /// user id 12345678. The band uses sex, age, height and weight to derive
  /// stride length, and from that the distance and calorie figures this app
  /// displays — so the app was feeding the band made-up anthropometrics and
  /// then presenting the results as measurements.
  ///
  /// Worse, it ran on every connection, overwriting whatever the user had
  /// configured in Zepp Life. A user who set their real height and weight there
  /// would have had it replaced by these constants the first time this app
  /// connected, and every time after.
  ///
  /// Leaving it uncalled means the band keeps the profile it already has, so
  /// distance and calories stay on whatever calibration the user set up. The
  /// code is kept because writing a *real* profile is the right feature — it
  /// needs a settings screen to collect one first (P11.2).
  // ignore: unused_element
  Future<void> _setUserInfo() async {
    if (_device == null || !_device!.isConnected) return;
    try {
      final userChar = await _findChar('fee0', '0008');
      if (userChar != null) {
        _logger.i("Sending user info to 0x0008...");
        final year = 1990;
        final month = 1;
        final day = 1;
        final sex = 0; // 0=male, 1=female, 2=other
        final height = 175;
        final weight200 = 70 * 200;
        final userid = 12345678;

        final bytes = [
          0x4f,
          0x00,
          0x00,
          year & 0xff,
          (year >> 8) & 0xff,
          month,
          day,
          sex,
          height & 0xff,
          (height >> 8) & 0xff,
          weight200 & 0xff,
          (weight200 >> 8) & 0xff,
          userid & 0xff,
          (userid >> 8) & 0xff,
          (userid >> 16) & 0xff,
          (userid >> 24) & 0xff
        ];
        // Send without response for configuration
        await userChar.write(bytes, withoutResponse: false);
      }
    } catch (e) {
      _logger.e("Failed to set user info: $e");
    }
  }

  // ---------------------------------------------------------------------------
  // Heart rate — standard GATT Heart-Rate service 0x180D
  //
  // RESOLVED (see docs/reverse-engineering/protocol-mb6.md §3, findings-02.md §2):
  // Mi Band 6 is a LEGACY Huami device — realtime HR does NOT use the Huami-2021
  // chunked channel (0x0016/0x0017). It uses the standard HR service:
  //   • measurement / notify  →  0x2A37  (in service 0x180D)
  //   • control point / write →  0x2A39
  // Commands written to 0x2A39 (confirmed in Gadgetbridge HuamiSupport AND the
  // decompiled Notify app x5/e.java):
  //   - [0x15, 0x01, 0x01]  start continuous (realtime) HR
  //   - [0x15, 0x01, 0x00]  stop continuous
  //   - [0x15, 0x02, 0x01]  one-shot / manual measurement
  //   - [0x15, 0x02, 0x00]  stop manual
  //   - [0x16]              KEEP-ALIVE ping — Notify resends this to 0x2A39 every
  //                         ~14 s while continuous HR is active, or the band stops
  //                         streaming (BLEManager.l1 / x5.e L()).
  // A 0x2A37 notification of [flags, bpm] yields bpm = data[1] & 0xFF (valid 7..249).
  //
  // The earlier GATT_WRITE_NOT_PERMITTED on enabling 0x2A37 was a sequencing issue
  // (Notify and Gadgetbridge both enable this CCCD fine on MB6 post-auth); we now
  // enable notify only after auth success + a short settle.
  // ---------------------------------------------------------------------------

  static const _hrStartContinuous = [0x15, 0x01, 0x01];
  static const _hrStopContinuous = [0x15, 0x01, 0x00];
  static const _hrStartManual = [0x15, 0x02, 0x01];
  static const _hrStopManual = [0x15, 0x02, 0x00];
  static const _hrKeepAlivePing = [0x16];

  bool get isRealtimeHeartRateActive => _realtimeHrActive;

  /// Enable third-party HR access (`06 1f 00 01` → config char fee0/0x0003).
  /// Tested in findings-05 — does NOT unlock the `0x2A37` CCCD on this firmware.
  /// Kept for reference / the gated runner's experiments.
  Future<void> enableHrThirdPartyAccess() async {
    await _writeConfig([0x06, 0x1f, 0x00, 0x01], 'enable HR third-party access');
  }

  /// Returns the device's current Android bond state (with a short timeout so it
  /// never hangs). Used by HR setup + the hardware test session.
  Future<BluetoothBondState> currentBondState() async {
    if (_device == null) return BluetoothBondState.none;
    try {
      return await _device!.bondState.first
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      return BluetoothBondState.none;
    }
  }

  /// Ensure the LE link is bonded/encrypted before touching the protected HR
  /// characteristic. On-device captures (findings-05) show the band reporting
  /// `Encryption LE: null` / "unbonded device" and rejecting the `0x2A37` CCCD
  /// with `GATT_WRITE_NOT_PERMITTED`, so we proactively create the bond.
  Future<void> _ensureLinkEncrypted() async {
    if (_device == null || !_device!.isConnected) return;
    try {
      final bond = await currentBondState();
      _logger.i('HR: link bond state = $bond');
      if (bond != BluetoothBondState.bonded) {
        _logger.i('HR: link not bonded — requesting createBond()...');
        await _device!.createBond();
        _logger.i('HR: createBond() done, bond = ${await currentBondState()}');
        await Future.delayed(const Duration(milliseconds: 400));
      }
    } catch (e) {
      _logger.e('HR: _ensureLinkEncrypted failed: $e');
    }
  }

  /// Discover the standard 0x180D HR characteristics and subscribe to 0x2A37.
  /// Safe to call multiple times.
  Future<bool> _setupHeartRate() async {
    if (_device == null || !_device!.isConnected) return false;
    if (_hrMeasureChar != null && _hrControlChar != null) return true;

    try {
      final services = await _discoverServicesCached();
      for (final svc in services) {
        if (!svc.uuid.str.toLowerCase().contains('180d')) continue;
        for (final c in svc.characteristics) {
          final cu = c.uuid.str.toLowerCase();
          if (cu.contains('2a37')) _hrMeasureChar = c;
          if (cu.contains('2a39')) _hrControlChar = c;
        }
      }

      if (_hrMeasureChar == null || _hrControlChar == null) {
        _logger.e('HR: 0x180D service or 0x2A37/0x2A39 chars not found '
            '(measure=${_hrMeasureChar != null}, control=${_hrControlChar != null}).');
        return false;
      }

      _logger.d('HR: 0x2A37 props notify=${_hrMeasureChar!.properties.notify}, '
          'indicate=${_hrMeasureChar!.properties.indicate}; '
          '0x2A39 props write=${_hrControlChar!.properties.write}, '
          'writeNR=${_hrControlChar!.properties.writeWithoutResponse}');

      // NOTE: the "expose HR to third party" command (06 1f 00 01 → fee0/0x0003)
      // was tested (findings-05) and does NOT unlock the 0x2A37 CCCD — refuted.
      // The captured root cause is the LE link not being encrypted/bonded; the
      // fix is established in _ensureLinkEncrypted() below.
      await _ensureLinkEncrypted();

      try {
        await _hrMeasureChar!.setNotifyValue(true);
        _logger.i('HR: notifications enabled on 0x2A37.');
      } catch (e) {
        _logger.e('HR: failed to enable 0x2A37 notify ($e). '
            'Realtime HR unavailable; HR history still comes from the activity fetch.');
        return false;
      }

      _hrSubscription?.cancel();
      _hrSubscription = _hrMeasureChar!.onValueReceived.listen(_onHeartRateNotified);
      return true;
    } catch (e) {
      _logger.e('HR setup error: $e');
      return false;
    }
  }

  /// Most recent RR intervals (ms) decoded from `0x2A37`, if the band ever
  /// sends them. Empty on this firmware — see [HeartRateMeasurement].
  final List<double> _rrIntervalsMs = [];
  List<double> get recentRrIntervalsMs => List.unmodifiable(_rrIntervalsMs);

  void _onHeartRateNotified(List<int> data) {
    _markPacket();
    if (data.length < 2) {
      _logger.d('HR notify (ignored, ${data.length}B): ${_hexStr(data)}');
      return;
    }

    // Full Heart Rate Measurement decode rather than a blind data[1].
    //
    // The old code took `data[1] & 0xFF` unconditionally. That happens to be
    // right for this firmware (every captured packet is 2 bytes, flags 0x00),
    // but it is wrong in two ways that would fail silently: if the band ever
    // set flags bit 0 (uint16 HR) we would read the low byte and look correct,
    // and if it ever sent RR intervals (bit 4) we would never notice. This is
    // also the RR probe requested in findings-20.
    final m = HeartRateMeasurement.parse(data);
    if (m == null) {
      _logger.d('HR notify (unparseable): ${_hexStr(data)}');
      return;
    }
    final bpm = m.bpm;

    if (m.rrIntervalsMs.isNotEmpty) {
      // Worth shouting about: it would mean real HRV becomes possible.
      _logger.i('HR: RR INTERVALS PRESENT (${m.rrIntervalsMs.length}) — '
          '${m.rrIntervalsMs.map((v) => v.toStringAsFixed(0)).join(",")} ms '
          '(raw ${_hexStr(data)})');
      _rrIntervalsMs.addAll(m.rrIntervalsMs);
      if (_rrIntervalsMs.length > 512) {
        _rrIntervalsMs.removeRange(0, _rrIntervalsMs.length - 512);
      }
    }

    _logger.dLazy(() => 'HR notify: ${_hexStr(data)} -> $bpm bpm '
        'flags=0x${data[0].toRadixString(16).padLeft(2, '0')} '
        '(uint16=${m.isUint16} contact=${m.sensorContact} '
        'energy=${m.energyExpended} rr=${m.rrIntervalsMs.length})');

    if (bpm >= 7 && bpm <= 249) {
      // Only the dedicated notifier fires here. Streaming HR arrives several
      // times a second; routing it through `notifyListeners()` used to rebuild
      // every tab (and re-run their full analysis passes) per beat. Widgets that
      // render the live number subscribe to `heartRateListenable` instead.
      _setHeartRate(bpm);
      // A live beat is not a history sync — see `_lastSyncTime`.
      activityStore.addHeartRateReadings(
          [HeartRateReading(timestamp: DateTime.now(), value: bpm)]);
      _storeSaveDebouncer(() => activityStore.save());
    }
  }

  Future<void> _writeHrControl(List<int> cmd, String label) async {
    if (_hrControlChar == null) return;
    try {
      // 0x2A39 advertises Write (with response) on MB6.
      await _hrControlChar!.write(cmd, withoutResponse: false);
      _logger.i('HR: wrote $label (${_hexStr(cmd)}) to 0x2A39.');
    } catch (e) {
      _logger.e('HR: failed to write $label: $e');
    }
  }

  /// Start continuous realtime HR streaming (with the required ~14 s keep-alive).
  Future<void> startRealtimeHeartRate() async {
    _userWantsHrStreaming = true;
    _storage.setWantsHrStreaming(true);
    if (!await _setupHeartRate()) return;
    await _writeHrControl(_hrStopManual, 'stop-manual');
    await _writeHrControl(_hrStartContinuous, 'start-continuous');
    _setRealtimeHrActive(true);

    // Keep-alive: the band stops streaming without a periodic 0x16 ping.
    // Notify pings ~every 14 s; we use 12 s for margin.
    _hrKeepAliveTimer?.cancel();
    _hrKeepAliveTimer =
        Timer.periodic(const Duration(seconds: 12), (_) async {
      if (!_realtimeHrActive || _device == null || !_device!.isConnected) {
        _hrKeepAliveTimer?.cancel();
        return;
      }
      await _writeHrControl(_hrKeepAlivePing, 'keep-alive');
    });
    _logger.i('HR: realtime measurement started.');
    _emitChange();
  }

  /// Switch the band to a low-power unattended overnight recording.
  ///
  /// Stops the 1 Hz realtime stream (which would flatten the band's battery
  /// long before morning) and turns on the band's own internal monitors, whose
  /// data is collected by the next activity fetch. See
  /// [BandConfigController.applySleepCaptureMode].
  Future<void> enterSleepCaptureMode(
      {HrInterval interval = HrInterval.oneMinute}) async {
    await stopRealtimeHeartRate();
    await bandConfig.applySleepCaptureMode(interval: interval);
    _logger.i('SLEEPCAP: band configured for overnight capture '
        '(battery=${_batteryLevel ?? '?'}%)');
  }

  /// Stop continuous realtime HR streaming.
  Future<void> stopRealtimeHeartRate() async {
    _userWantsHrStreaming = false;
    _storage.setWantsHrStreaming(false);
    _hrKeepAliveTimer?.cancel();
    _setRealtimeHrActive(false);
    await _writeHrControl(_hrStopContinuous, 'stop-continuous');
    _logger.i('HR: realtime measurement stopped.');
    _emitChange();
  }

  /// Trigger a single one-shot HR measurement (battery-friendly).
  Future<void> measureHeartRateOnce() async {
    if (!await _setupHeartRate()) return;
    await _writeHrControl(_hrStopContinuous, 'stop-continuous');
    await _writeHrControl(_hrStopManual, 'stop-manual');
    await _writeHrControl(_hrStartManual, 'start-manual');
    _logger.i('HR: one-shot measurement requested.');
  }

  // ---------------------------------------------------------------------------
  // Battery level
  //
  // Mi Band 6 (legacy Huami) reports battery on the custom char fee0/0x0006:
  //   payload = [flags, level%, chargeState, ...]  -> level is byte[1].
  // (Confirmed in Gadgetbridge HuamiBatteryInfo and the decompiled Notify app
  //  r6/b.java; see protocol-mb6.md §4.) We fall back to the standard
  //  0x180F/0x2A19 service (level in byte[0]) if 0x0006 is unavailable.
  // ---------------------------------------------------------------------------

  Future<void> _readBattery() async {
    if (_device == null || !_device!.isConnected) return;

    try {
      final services = await _discoverServicesCached();

      // Preferred: Huami fee0/0x0006 (level in byte[1]).
      for (final svc in services) {
        if (!svc.uuid.str.toLowerCase().contains('fee0')) continue;
        for (final c in svc.characteristics) {
          if (c.uuid.str.toLowerCase().contains('0006')) {
            _battChar = c;
            break;
          }
        }
      }

      if (_battChar != null) {
        final raw = await _battChar!.read();
        _applyHuamiBattery(raw);
        try {
          await _battChar!.setNotifyValue(true);
          _battSubscription?.cancel();
          _battSubscription =
              _battChar!.onValueReceived.listen(_applyHuamiBattery);
        } catch (_) {}
        return;
      }

      // Fallback: standard battery service 0x180F / 0x2A19 (level in byte[0]).
      BluetoothCharacteristic? stdBatt;
      for (final svc in services) {
        if (!svc.uuid.str.toLowerCase().contains('180f')) continue;
        for (final char in svc.characteristics) {
          if (char.uuid.str.toLowerCase().contains('2a19')) {
            stdBatt = char;
            break;
          }
        }
      }
      if (stdBatt == null) {
        _logger.e("Battery: neither fee0/0x0006 nor 0x2a19 found.");
        return;
      }
      final raw = await stdBatt.read();
      if (raw.isNotEmpty) {
        _setBatteryLevel(raw[0].clamp(0, 100));
        _logger.i("Battery (0x2a19): $_batteryLevel%");
        _emitChange();
      }
      try {
        await stdBatt.setNotifyValue(true);
        _battSubscription?.cancel();
        _battSubscription = stdBatt.onValueReceived.listen((data) {
          if (data.isNotEmpty) {
            _setBatteryLevel(data[0].clamp(0, 100));
            _logger.d("Battery update (0x2a19): $_batteryLevel%");
            _emitChange();
          }
        });
      } catch (_) {}
    } catch (e) {
      _logger.e("Battery read error: $e");
    }
  }

  void _applyHuamiBattery(List<int> raw) {
    _markPacket();
    // [flags, level%, chargeState, ...] — level is byte[1].
    if (raw.length < 2) {
      _logger.d("Battery (0x0006) short packet: ${_hexStr(raw)}");
      return;
    }
    _setBatteryLevel(raw[1].clamp(0, 100));
    final charging = raw.length >= 3 && raw[2] == 0x01;
    _logger.i("Battery (0x0006): $_batteryLevel%${charging ? ' (charging)' : ''}");
    _emitChange();
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  String _hexStr(List<int> data) =>
      data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

  bool _disposed = false;

  /// Immediate, un-coalesced emit. Only [_uiCoalescer] should call this.
  void _emitNow() {
    if (!_disposed) notifyListeners();
  }

  /// Request a UI refresh, rate-limited to ~4 Hz.
  ///
  /// Every former direct `notifyListeners()` call in this class routes through
  /// here, so a burst of BLE traffic can no longer schedule a rebuild per
  /// packet. Use [_emitImmediate] for rare, user-visible transitions where the
  /// 250 ms trailing delay would be felt.
  void _emitChange() => _uiCoalescer.schedule();

  /// Bypass the coalescer for a state change the user is waiting on (connect,
  /// auth result, explicit disconnect).
  void _emitImmediate() {
    _uiCoalescer.flush();
    _emitNow();
  }

  /// Keeps [authStateListenable] — and the coarser [ConnectionPhase] — in sync
  /// with [_authState]. Authentication is a phase of connecting, so the two
  /// must never be able to disagree.
  void _setAuthState(AuthState state) {
    _authState = state;
    authStateListenable.value = state;
    switch (state) {
      case AuthState.authenticating:
        _setPhase(ConnectionPhase.authenticating);
      case AuthState.authenticated:
        _setPhase(ConnectionPhase.ready);
      case AuthState.failed:
      case AuthState.notAuthenticated:
        break; // the disconnect/retry paths own the phase here
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _uiCoalescer.dispose();
    _metricsSaveDebouncer.dispose();
    _storeSaveDebouncer.dispose();
    _cancelSupervision();
    _authTimeoutTimer?.cancel();
    _reconnectTimer?.cancel();
    _hrKeepAliveTimer?.cancel();
    _syncTimer?.cancel();
    _stepsPollTimer?.cancel();
    connectionPhaseListenable.dispose();
    _connSubscription?.cancel();
    _battSubscription?.cancel();
    _battSubscription = null;
    for (final sub in _initCharSubs) {
      sub.cancel();
    }
    _initCharSubs.clear();
    _charSubscription?.cancel();
    _stepsSubscription?.cancel();
    _hrSubscription?.cancel();
    heartRateListenable.dispose();
    batteryListenable.dispose();
    metricsListenable.dispose();
    authStateListenable.dispose();
    fetchingListenable.dispose();
    realtimeHrListenable.dispose();
    super.dispose();
  }

  Future<void> safeWrite(List<int> value) async {
    if (_device == null || !_device!.isConnected) {
      _logger.e("Tried to write but device disconnected");
      return;
    }
    if (_authChar != null) {
      try {
        // The canonical 0x0009 auth char is Write-Without-Response (like the
        // other Huami chars); fec1 is Write-With-Response. Pick by property.
        final noResp = !_authChar!.properties.write &&
            _authChar!.properties.writeWithoutResponse;
        await _authChar!.write(value, withoutResponse: noResp);
      } catch (e) {
        _logger.e("Write error: $e");
      }
    }
  }

  void _failAuth() {
    _isAuthenticating = false;
    _setAuthState(AuthState.failed);
    _emitChange();
  }

  /// Explicit user-initiated disconnect. Clears the saved device and the
  /// "wants connected" intent, so neither the supervisor nor the next app
  /// launch tries to reconnect.
  Future<void> disconnect() async {
    _userDisconnected = true;
    await stopSupervision();
    _isReconnecting = false;
    await _storage.clearLastDeviceId();
    await _stopForegroundService();
    _logger.i("Disconnecting (user initiated) — saved device cleared.");
    await _device?.disconnect();
    _device = null;
    _flushPendingWrites();
    _emitImmediate();
  }
}
