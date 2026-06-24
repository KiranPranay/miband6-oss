import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'dart:math';
import 'logger.dart';
import 'encryption.dart';
import '../storage/secure_storage.dart';
import 'dart:typed_data';
import 'band_metrics.dart';
import 'activity_sample.dart';
import 'activity_fetcher.dart';
import '../storage/activity_store.dart';
import 'alert_manager.dart';
import 'ecdh_b163.dart';
import 'huami2021_chunked.dart';

part 'hardware_test_session.dart';
part 'huami2021_auth.dart';

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

class BLEManager extends ChangeNotifier {
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
  Timer? _authTimeoutTimer;
  Timer? _reconnectTimer;
  Timer? _hrKeepAliveTimer;
  bool _realtimeHrActive = false;

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

  BandMetrics _metrics = const BandMetrics();
  int? _batteryLevel;
  int? _heartRate;
  DateTime? _lastSyncTime;

  ActivityFetcher? _activityFetcher;
  final ActivityStore activityStore = ActivityStore();
  late final AlertManager alertManager = AlertManager(_logger);
  bool _isFetchingActivity = false;

  bool get isConnected => _device != null && _device!.isConnected;
  bool _isAuthenticating = false;
  AuthState _authState = AuthState.notAuthenticated;

  BLEManager(this._logger, this._storage) {
    _loadPersistedData();
    activityStore.load();
  }

  BluetoothDevice? get device => _device;
  AuthState get authState => _authState;
  bool get isAuthenticating => _isAuthenticating;
  bool get isReconnecting => _isReconnecting;
  BandMetrics get metrics => _metrics;
  int? get batteryLevel => _batteryLevel;
  int? get heartRate => _heartRate;
  DateTime? get lastSyncTime => _lastSyncTime;
  bool get isFetchingActivity => _isFetchingActivity;

  // ---------------------------------------------------------------------------
  // Persistent data
  // ---------------------------------------------------------------------------

  Future<void> _loadPersistedData() async {
    await activityStore.load();
    _lastSyncTime = activityStore.lastActivitySync;
    notifyListeners();
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
        autoRunOnBoot: false,
        allowWakeLock: true,
      ),
    );
  }

  Future<void> _startForegroundService() async {
    if (await FlutterForegroundTask.isRunningService) return;
    _initForegroundTaskConfig();
    await FlutterForegroundTask.startService(
      serviceId: 1001,
      notificationTitle: 'Mi Band',
      notificationText: 'Connected — keeping band alive',
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

  // ---------------------------------------------------------------------------
  // Auto-connect on app startup
  // ---------------------------------------------------------------------------

  /// Call this once at app startup. Reads the saved device MAC and connects
  /// automatically — no user action needed.
  Future<void> tryAutoConnect() async {
    final savedId = await _storage.getLastDeviceId();
    if (savedId == null || savedId.isEmpty) {
      _logger.d("No saved device ID — skipping auto-connect.");
      return;
    }
    _logger.i("Auto-connect: found saved device $savedId. Connecting...");
    final device = BluetoothDevice.fromId(savedId);
    await connect(device);
  }

  // ---------------------------------------------------------------------------
  // Connection
  // ---------------------------------------------------------------------------

  Future<void> connect(BluetoothDevice target) async {
    _userDisconnected = false;
    _logger.i("Connecting to ${target.remoteId}...");
    _device = target;
    notifyListeners();

    _connSubscription?.cancel();
    _reconnectTimer?.cancel();
    _isReconnecting = false;
    _connSubscription = target.connectionState.listen((state) {
      _logger.i("Connection state: $state");
      if (state == BluetoothConnectionState.disconnected) {
        _handleDisconnect();
      } else if (state == BluetoothConnectionState.connected) {
        _handleConnected();
      }
      notifyListeners();
    });

    try {
      await target.connect(autoConnect: false);
    } catch (e) {
      _logger.e("Connect error: $e");
    }
  }

  void _handleDisconnect() {
    _isAuthenticating = false;
    _authState = AuthState.notAuthenticated;
    _authChar = null;
    _stepsChar = null;
    _hrMeasureChar = null;
    _hrControlChar = null;
    _battChar = null;
    _charSubscription?.cancel();
    _stepsSubscription?.cancel();
    _hrSubscription?.cancel();
    _hrKeepAliveTimer?.cancel();
    _realtimeHrActive = false;
    _disposeChunked();
    // NOTE: _metrics is intentionally NOT reset — we keep the last known values
    // so the UI can still display historical data while disconnected.
    _batteryLevel = null;
    _heartRate = null;
    _logger.e("Device disconnected.");

    _stopForegroundService();

    if (!_userDisconnected && _device != null) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _isReconnecting = true;
    notifyListeners();
    _logger.i("Will attempt reconnect in 3 s...");
    _reconnectTimer = Timer(const Duration(seconds: 3), () async {
      if (_userDisconnected || _device == null) {
        _isReconnecting = false;
        notifyListeners();
        return;
      }
      _logger.i("Reconnecting to ${_device!.remoteId}...");
      try {
        await _device!.connect(autoConnect: false);
      } catch (e) {
        _logger.e("Reconnect error: $e — retrying in 5 s");
        _reconnectTimer = Timer(const Duration(seconds: 5), _scheduleReconnect);
      }
    });
  }

  Future<void> _handleConnected() async {
    _reconnectTimer?.cancel();
    _isReconnecting = false;
    _logger.i("Connected successfully.");
    if (_device == null) return;

    // Save MAC so we can auto-connect on next app launch
    await _storage.saveLastDeviceId(_device!.remoteId.str);

    // Start foreground service to keep process alive in background
    await _startForegroundService();

    try {
      await _device!.requestMtu(247);
      _logger.d("Requested MTU 247");
    } catch (e) {
      _logger.e("MTU request failed: $e");
    }

    _logger.i("Discovering services...");
    List<BluetoothService> services = await _device!.discoverServices();

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
    _authState = AuthState.authenticating;
    notifyListeners();

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

      final authKeyHex =
          authKeyBytes.map((e) => e.toRadixString(16).padLeft(2, '0')).join();
      _logger.d("Auth key (hex): $authKeyHex");
      _logger.d("Auth key length: ${authKeyBytes.length} bytes");

      _authTimeoutTimer?.cancel();
      _authTimeoutTimer = Timer(const Duration(seconds: 20), () {
        _logger.e("Auth timeout");
        _isAuthenticating = false;
        _authState = AuthState.failed;
        notifyListeners();
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
      _authState = AuthState.failed;
      notifyListeners();
    }
  }

  void _handleAuthResponse(List<int> response) async {
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
        _authState = AuthState.authenticated;
        notifyListeners();
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
    _updateForegroundNotification('Connected & authenticated');

    // Step 1: Sync time (critical for some bands to enable other features)
    await _syncTime();
    await Future.delayed(const Duration(milliseconds: 300));

    // Step 2: Initialize display & settings
    await _setDateDisplay();
    await _setTimeFormat();
    await _setUserInfo();
    await _setFitnessGoal(10000); // 10k steps default

    // Step 3: Subscriptions
    await _subscribeToSteps();
    await _readBattery();
    // Realtime HR over the standard 0x180D service (0x2A37/0x2A39) with the
    // required ~14 s keep-alive ping. See protocol-mb6.md §3.
    await startRealtimeHeartRate();

    await Future.delayed(const Duration(seconds: 2));

    // Step 4: Initial fetch
    _fetchActivityData();
  }

  Future<void> _syncTime() async {
    if (_device == null || !_device!.isConnected) return;

    // Find the current time characteristic (0x2A2B in fee0)
    BluetoothCharacteristic? timeChar;
    try {
      final services = await _device!.discoverServices();
      for (final svc in services) {
        if (svc.uuid.str.toLowerCase().contains('fee0')) {
          for (final c in svc.characteristics) {
            if (c.uuid.str.toLowerCase().contains('2a2b')) {
              timeChar = c;
              break;
            }
          }
        }
      }
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

  Future<void> _setFitnessGoal(int steps) async {
    if (_device == null || !_device!.isConnected) return;
    try {
      BluetoothCharacteristic? configChar;
      final services = await _device!.discoverServices();
      for (final svc in services) {
        if (svc.uuid.str.toLowerCase().contains('fee0')) {
          for (final c in svc.characteristics) {
            if (c.uuid.str.toLowerCase().contains('0003')) {
              configChar = c;
              break;
            }
          }
        }
      }
      if (configChar != null) {
        _logger.i("Setting fitness goal: $steps steps...");
        // Command: 0x10, 0x0, 0x0, steps_lo, steps_hi, 0, 0
        final cmd = [
          0x10,
          0x00,
          0x00,
          steps & 0xff,
          (steps >> 8) & 0xff,
          0x00,
          0x00
        ];
        await configChar.write(cmd, withoutResponse: true);
      }
    } catch (e) {
      _logger.e("Failed to set fitness goal: $e");
    }
  }

  Future<void> _fetchActivityData() async {
    if (_device == null || !_device!.isConnected) return;

    _isFetchingActivity = true;
    notifyListeners();

    try {
      _activityFetcher = ActivityFetcher(_logger, _device!);
      final ok = await _activityFetcher!.init();
      if (!ok) {
        _logger.e('Activity fetch: init failed');
        return;
      }

      // Choose the fetch window: backfill a week until we have a few days of
      // history stored, then fetch incrementally (with a 6 h overlap so gaps
      // around the boundary are re-pulled). Samples are de-duplicated by
      // timestamp in the store, so overlap is harmless.
      final lastSync = activityStore.lastActivitySync;
      final now = DateTime.now();
      final earliest = activityStore.samples.isNotEmpty
          ? activityStore.samples.first.timestamp
          : now;
      final haveDeepHistory =
          earliest.isBefore(now.subtract(const Duration(days: 3)));
      final since = (lastSync != null && haveDeepHistory)
          ? lastSync.subtract(const Duration(hours: 6))
          : now.subtract(const Duration(days: 7));

      // One activity fetch yields steps, sleep AND heart-rate history — HR is
      // embedded at byte 3 of each 8-byte sample (see protocol-mb6.md §5).
      _logger.i('Fetching Activity/Sleep/HR Data since $since '
          '(deepHistory=$haveDeepHistory)');
      final samples = await _activityFetcher!.fetchActivityData(since);
      if (samples.isNotEmpty) {
        activityStore.addSamples(samples);
        activityStore.updateActivitySync(DateTime.now());
        _logger.i('Activity fetch: got ${samples.length} samples');

        final hrReadings = ActivityFetcher.heartRatesFromSamples(samples);
        if (hrReadings.isNotEmpty) {
          activityStore.addHeartRateReadings(hrReadings);
          activityStore.updateHrSync(DateTime.now());
          _logger.i('HR history: derived ${hrReadings.length} readings from activity');
        }
      } else {
        _logger.i('Activity fetch: no new samples');
      }

      _logger.i('Fetching SPO2 History since $since');
      final spo2 = await _activityFetcher!.fetchSpo2(since);
      if (spo2.isNotEmpty) {
        activityStore.addSpo2Readings(spo2);
        activityStore.updateSpo2Sync(DateTime.now());
        _logger.i('SPO2 fetch: got ${spo2.length} readings');
      } else {
        _logger.i('SPO2 fetch: no new data');
      }

      // Persist
      await activityStore.save();
    } catch (e) {
      _logger.e('Activity fetch error: $e');
    } finally {
      _isFetchingActivity = false;
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------------------
  // Real-time steps  (fee0 / 0x0007)
  // ---------------------------------------------------------------------------

  Future<void> _subscribeToSteps() async {
    if (_device == null || !_device!.isConnected) return;

    try {
      final services = await _device!.discoverServices();
      BluetoothService? fee0;
      for (final svc in services) {
        if (svc.uuid.str.toLowerCase().contains('fee0')) {
          fee0 = svc;
          break;
        }
      }
      if (fee0 == null) {
        _logger.e("Steps: fee0 service not found.");
        return;
      }

      for (final char in fee0.characteristics) {
        if (char.uuid.str.toLowerCase().contains('0007')) {
          _stepsChar = char;
          break;
        }
      }
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
    } catch (e) {
      _logger.e("Steps subscription error: $e");
    }
  }

  void _applyStepsPacket(List<int> data) {
    final parsed = BandMetrics.fromStepsPacket(data);
    if (parsed != null) {
      _metrics = parsed;
      _lastSyncTime = DateTime.now();
      _logger.i("Steps: ${parsed.steps} steps, ${parsed.distanceMeters} m, "
          "${parsed.calories} kcal");
      _storage.saveMetrics(_metrics);
      _storage.saveLastSyncTime(_lastSyncTime!);
      notifyListeners();
    } else {
      _logger.d("Steps: packet not parseable (${data.length} B)");
    }
  }

  // ---------------------------------------------------------------------------
  // Missing Notifications from Gadgetbridge Phase2/3
  // ---------------------------------------------------------------------------

  Future<void> _subscribeToMissingNotifications() async {
    if (_device == null || !_device!.isConnected) return;
    try {
      final services = await _device!.discoverServices();
      for (final svc in services) {
        if (svc.uuid.str.toLowerCase().contains('fee0')) {
          for (final char in svc.characteristics) {
            final cu = char.uuid.str.toLowerCase();
            // Subscribing to 0x0003 (config), 0x0010 (device events), 0x000F (notifs)
            if (cu.contains('0003') ||
                cu.contains('000f') ||
                cu.contains('0010')) {
              _logger.i("Subscribing to init characteristic $cu...");
              await char.setNotifyValue(true);
              char.onValueReceived.listen((data) {
                _logger.d(
                    "Init Char $cu data: ${data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}");
              });
            }
          }
        }
      }
    } catch (e) {
      _logger.e("Init chars subscription failed: $e");
    }
  }

  Future<void> _setDateDisplay() async {
    await _writeConfig([0x06, 0x0a, 0x00, 0x03], "date display");
  }

  Future<void> _setTimeFormat() async {
    // 24h format: 0x06, 0x02, 0x00, 0x01
    await _writeConfig([0x06, 0x02, 0x00, 0x01], "24h time format");
  }

  Future<void> _writeConfig(List<int> cmd, String label) async {
    if (_device == null || !_device!.isConnected) return;
    try {
      BluetoothCharacteristic? configChar;
      final services = await _device!.discoverServices();
      for (final svc in services) {
        if (svc.uuid.str.toLowerCase().contains('fee0')) {
          for (final c in svc.characteristics) {
            if (c.uuid.str.toLowerCase().contains('0003')) {
              configChar = c;
              break;
            }
          }
        }
      }
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

  Future<void> _setUserInfo() async {
    if (_device == null || !_device!.isConnected) return;
    try {
      BluetoothCharacteristic? userChar;
      final services = await _device!.discoverServices();
      for (final svc in services) {
        if (svc.uuid.str.toLowerCase().contains('fee0')) {
          for (final char in svc.characteristics) {
            if (char.uuid.str.toLowerCase().contains('0008')) {
              userChar = char;
              break;
            }
          }
        }
      }
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
      final services = await _device!.discoverServices();
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

  void _onHeartRateNotified(List<int> data) {
    if (data.length < 2) {
      _logger.d('HR notify (ignored, ${data.length}B): ${_hexStr(data)}');
      return;
    }
    // [flags, bpm] — bpm is data[1] (uint8). Valid physiological range 7..249.
    final bpm = data[1] & 0xFF;
    _logger.d('HR notify: ${_hexStr(data)} -> $bpm bpm');
    if (bpm >= 7 && bpm <= 249) {
      _heartRate = bpm;
      _lastSyncTime = DateTime.now();
      activityStore.addHeartRateReadings(
          [HeartRateReading(timestamp: _lastSyncTime!, value: bpm)]);
      notifyListeners();
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
    if (!await _setupHeartRate()) return;
    await _writeHrControl(_hrStopManual, 'stop-manual');
    await _writeHrControl(_hrStartContinuous, 'start-continuous');
    _realtimeHrActive = true;

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
    notifyListeners();
  }

  /// Stop continuous realtime HR streaming.
  Future<void> stopRealtimeHeartRate() async {
    _hrKeepAliveTimer?.cancel();
    _realtimeHrActive = false;
    await _writeHrControl(_hrStopContinuous, 'stop-continuous');
    _logger.i('HR: realtime measurement stopped.');
    notifyListeners();
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
      final services = await _device!.discoverServices();

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
        _batteryLevel = raw[0].clamp(0, 100);
        _logger.i("Battery (0x2a19): $_batteryLevel%");
        notifyListeners();
      }
      try {
        await stdBatt.setNotifyValue(true);
        stdBatt.onValueReceived.listen((data) {
          if (data.isNotEmpty) {
            _batteryLevel = data[0].clamp(0, 100);
            _logger.d("Battery update (0x2a19): $_batteryLevel%");
            notifyListeners();
          }
        });
      } catch (_) {}
    } catch (e) {
      _logger.e("Battery read error: $e");
    }
  }

  void _applyHuamiBattery(List<int> raw) {
    // [flags, level%, chargeState, ...] — level is byte[1].
    if (raw.length < 2) {
      _logger.d("Battery (0x0006) short packet: ${_hexStr(raw)}");
      return;
    }
    _batteryLevel = raw[1].clamp(0, 100);
    final charging = raw.length >= 3 && raw[2] == 0x01;
    _logger.i("Battery (0x0006): $_batteryLevel%${charging ? ' (charging)' : ''}");
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  String _hexStr(List<int> data) =>
      data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

  /// Internal forwarder so the [HardwareTestSession] extension (a different
  /// scope than this class) can request a UI refresh without touching the
  /// `@protected` notifyListeners directly.
  void _emitChange() => notifyListeners();

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
    _authState = AuthState.failed;
    notifyListeners();
  }

  /// Explicit user-initiated disconnect. Clears the saved device so the next
  /// app launch does NOT auto-reconnect.
  Future<void> disconnect() async {
    _userDisconnected = true;
    _reconnectTimer?.cancel();
    _isReconnecting = false;
    await _storage.clearLastDeviceId();
    await _stopForegroundService();
    _logger.i("Disconnecting (user initiated) — saved device cleared.");
    await _device?.disconnect();
    _device = null;
    notifyListeners();
  }
}
