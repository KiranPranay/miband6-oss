part of 'ble_manager.dart';

/// Where the connection currently is, as one explicit value.
///
/// Before this existed the UI had to infer connection state from four loosely
/// related booleans (`isConnected`, `isAuthenticating`, `isReconnecting`,
/// `authState`), which could disagree — e.g. `isConnected == true` while the
/// link was actually dead because the band had gone out of range without the
/// stack noticing.
enum ConnectionPhase {
  /// No band paired, or the user explicitly disconnected.
  idle,

  /// Bluetooth is off at the adapter level; nothing to do until it returns.
  bluetoothOff,

  /// Looking for the band (only used when a direct connect by MAC is not
  /// possible).
  scanning,

  /// GATT connect in flight.
  connecting,

  /// Link up, running the sign-key handshake.
  authenticating,

  /// Authenticated, subscriptions armed — the normal working state.
  ready,

  /// Backing off before the next attempt.
  waitingToRetry,
}

extension ConnectionPhaseLabel on ConnectionPhase {
  /// Short human-readable label for the persistent notification and the UI
  /// status chip. Never an exception string.
  String get label => switch (this) {
        ConnectionPhase.idle => 'Not connected',
        ConnectionPhase.bluetoothOff => 'Bluetooth off',
        ConnectionPhase.scanning => 'Searching…',
        ConnectionPhase.connecting => 'Connecting…',
        ConnectionPhase.authenticating => 'Authenticating…',
        ConnectionPhase.ready => 'Connected',
        ConnectionPhase.waitingToRetry => 'Reconnecting…',
      };
}

/// Connection supervision: auto-reconnect, adapter awareness and a liveness
/// heartbeat.
///
/// Replaces the previous strategy, which was a fixed 3 s timer that, on error,
/// scheduled `_scheduleReconnect` again after 5 s — so a band that was simply
/// out of range was retried forever at a near-constant rate, and an adapter
/// switched off produced a tight failing loop. There was also no detection at
/// all for the common BLE failure where the link is nominally "connected" but
/// no data ever arrives again.
extension ConnectionSupervisor on BLEManager {
  /// If nothing at all arrives from the band for this long while we believe we
  /// are connected, the link is presumed dead and torn down. The band sends
  /// battery/steps notifications well inside this window, and the HR keep-alive
  /// (12 s) provokes traffic whenever streaming is on.
  static const Duration _livenessTimeout = Duration(minutes: 5);

  /// How often to check the liveness deadline.
  static const Duration _heartbeatPeriod = Duration(minutes: 1);

  // ── Public control ────────────────────────────────────────────────────────

  /// Declare that the user wants the band connected, and start supervising.
  ///
  /// Idempotent. Persisted, so a later app launch (or a foreground-service
  /// restart after the task is removed) resumes on its own.
  Future<void> startSupervision({BluetoothDevice? target}) async {
    _userWantsConnected = true;
    _userDisconnected = false;
    await _storage.setWantsConnected(true);
    _listenToAdapterState();
    _startHeartbeat();
    if (target != null) {
      await connect(target);
    } else {
      await _attemptConnect();
    }
  }

  /// Stop supervising and drop the link. Survives app restarts.
  Future<void> stopSupervision() async {
    _userWantsConnected = false;
    await _storage.setWantsConnected(false);
    _cancelSupervision();
    _setPhase(ConnectionPhase.idle);
  }

  void _cancelSupervision() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _adapterSub?.cancel();
    _adapterSub = null;
  }

  // ── Adapter awareness ─────────────────────────────────────────────────────

  void _listenToAdapterState() {
    _adapterSub?.cancel();
    _adapterSub = FlutterBluePlus.adapterState.listen((state) {
      if (state == BluetoothAdapterState.on) {
        _logger.i('Supervisor: Bluetooth adapter ON');
        if (_userWantsConnected && !isConnected) {
          // A fresh adapter is a fresh chance — do not serve out the old
          // backoff, the previous failures were caused by the radio being off.
          _backoff.reset();
          _attemptConnect();
        }
      } else if (state == BluetoothAdapterState.off) {
        _logger.e('Supervisor: Bluetooth adapter OFF — pausing reconnects');
        _reconnectTimer?.cancel();
        _reconnectTimer = null;
        _setPhase(ConnectionPhase.bluetoothOff);
      }
    });
  }

  // ── Reconnect loop ────────────────────────────────────────────────────────

  /// Schedule the next attempt using the backoff schedule. Retries forever
  /// while the user wants to be connected — a band out of range for an hour
  /// must still reconnect by itself when it comes back.
  void _scheduleReconnectWithBackoff() {
    if (!_userWantsConnected || _userDisconnected) return;
    _reconnectTimer?.cancel();

    final delay = _backoff.next();
    _setPhase(ConnectionPhase.waitingToRetry);
    _logger.i('Supervisor: retry #${_backoff.attempt} in '
        '${(delay.inMilliseconds / 1000).toStringAsFixed(1)} s');
    _updateForegroundNotification('Reconnecting…');

    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      _attemptConnect();
    });
  }

  /// One connection attempt. Prefers a direct connect by MAC — the band's
  /// address is known after the first pairing, and scanning first is both
  /// slower and less reliable when the band is advertising infrequently.
  Future<void> _attemptConnect() async {
    if (!_userWantsConnected || _userDisconnected) return;
    if (isConnected) return;

    final savedId = await _storage.getLastDeviceId();
    if (savedId == null || savedId.isEmpty) {
      _logger.d('Supervisor: no saved device — nothing to connect to');
      _setPhase(ConnectionPhase.idle);
      return;
    }

    // Do not burn a retry while the radio is off; the adapter listener will
    // kick us as soon as it returns.
    final adapter = await FlutterBluePlus.adapterState.first
        .timeout(const Duration(seconds: 2), onTimeout: () => BluetoothAdapterState.unknown);
    if (adapter == BluetoothAdapterState.off) {
      _setPhase(ConnectionPhase.bluetoothOff);
      return;
    }

    _setPhase(ConnectionPhase.connecting);
    final device = BluetoothDevice.fromId(savedId);
    _logger.i('Supervisor: connecting to $savedId '
        '(attempt ${_backoff.attempt + 1})');
    try {
      await connect(device);
    } catch (e) {
      _logger.e('Supervisor: connect attempt failed: $e');
      _scheduleReconnectWithBackoff();
    }
  }

  // ── Liveness heartbeat ────────────────────────────────────────────────────

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(_heartbeatPeriod, (_) {
      if (!_userWantsConnected) return;
      if (!isConnected) {
        // Believed disconnected and no retry queued (e.g. a timer was lost
        // across a process freeze) — restart the loop.
        if (_reconnectTimer == null &&
            _connectionPhase != ConnectionPhase.bluetoothOff) {
          _logger.i('Supervisor: heartbeat found no pending retry — resuming');
          _attemptConnect();
        }
        return;
      }
      final last = _lastPacketAt;
      if (last == null) return;
      final silence = DateTime.now().difference(last);
      if (silence > _livenessTimeout) {
        // "Connected" but silent: the classic half-open BLE link. Nothing will
        // recover this except tearing the link down and reconnecting.
        _logger.e('Supervisor: no packet for ${silence.inMinutes} min while '
            'connected — forcing a reconnect cycle');
        _forceReconnectCycle();
      }
    });
  }

  Future<void> _forceReconnectCycle() async {
    try {
      await _device?.disconnect();
    } catch (e) {
      _logger.d('Supervisor: disconnect during forced cycle threw: $e');
    }
    // _handleDisconnect() schedules the next attempt via the backoff path.
  }
}
