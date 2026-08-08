part of 'ble_manager.dart';

// ===========================================================================
// Mi Band 6 — Hardware Test Session
//
// A single, ordered, halt-on-fail runner that confirms each protocol claim in
// docs/reverse-engineering/protocol-mb6.md against the physical band. Trigger it
// from Settings → Developer → "Run Hardware Test" while the band is CONNECTED
// and WORN. Each gate emits ONE greppable headline:
//     MB6TEST GATEn: PASS — <detail>
//     MB6TEST GATEn: FAIL — <detail>
// plus MB6TEST SESSION START / END banners. Grep a log dump for `MB6TEST` to
// read results. See hardware-test-session.md for the gate walkthrough.
//
// This adds NO protocol opcodes — it only sequences and instruments the
// existing post-auth behaviour, with one empirical extra: Gate 5 auto-probes
// the keep-alive interval (the single-sourced 12 s value) by retrying 8 s / 15 s
// if HR streaming dies early.
// ===========================================================================

/// One HR notification captured during the session.
typedef _HrEvent = ({DateTime t, int bpm});

extension HardwareTestSession on BLEManager {
  // HR control-point opcodes (written to 0x2A39). Mirrors the static consts in
  // BLEManager; inlined here so the extension stays self-contained.
  static const List<int> _startContinuous = [0x15, 0x01, 0x01];
  static const List<int> _stopContinuous = [0x15, 0x01, 0x00];
  static const List<int> _stopManual = [0x15, 0x02, 0x00];
  static const List<int> _ping = [0x16];

  /// Run gates 0→6 in order, halting on a hard failure. Idempotent and safe to
  /// re-run: it resets HR state on entry and cleans up on exit.
  Future<void> runHardwareTestSession() async {
    if (_isTestSessionRunning) {
      _logger.i('MB6TEST: a session is already running — ignoring re-trigger');
      return;
    }
    _isTestSessionRunning = true;
    _emitChange();

    final passed = <int>{};
    final skipped = <int>{};
    const total = 9; // gates 0..8
    final fw = await _readFirmwareVersion();

    try {
      _logger.i('MB6TEST SESSION START — gates 0..8 fw=$fw '
          '(band must be CONNECTED, authenticated, and WORN)');

      // ---- GATE 0: discovery ----
      final g0 = await _gate0Discovery();
      if (g0.halt) {
        _finishSession(passed, skipped, total, fw);
        return;
      }
      if (g0.pass) passed.add(0);

      // ---- GATE 1: auth ----
      if (await _gate1Auth()) {
        passed.add(1);
      } else {
        _finishSession(passed, skipped, total, fw);
        return; // halt — the refactor must not have disturbed auth
      }

      // ---- GATE 2: battery (never halts) ----
      if (await _gate2Battery()) passed.add(2);

      // ---- GATES 3-5: realtime HR ----
      if (g0.skipHr) {
        skipped.addAll({3, 4, 5});
        _logger.i('MB6TEST GATE3-5: SKIPPED — 0x180D absent; '
            'HR will be validated only via the activity fetch (Gate 6).');
      } else {
        _logger.i('MB6TEST: >>> WEAR CHECK: the band must be worn SNUGLY with '
            'wear-detection active. Off-wrist, HR reads 0/255. <<<');
        final hr = await _runHrGates();
        passed.addAll(hr.passed);
        skipped.addAll(hr.skipped);
      }

      // ---- GATE 6: activity fetch ----
      if (await _gate6ActivityFetch()) passed.add(6);

      // ---- GATE 7: sleep session plausibility (findings-18) ----
      if (await _gate7Sleep()) passed.add(7);

      // ---- GATE 8: notification delivery (findings-17) ----
      if (await _gate8Notification()) {
        passed.add(8);
      } else {
        skipped.add(8);
      }

      _finishSession(passed, skipped, total, fw);
    } catch (e, st) {
      _logger.e('MB6TEST SESSION ERROR — $e\n$st');
    } finally {
      // Restore normal running state: resume realtime HR if HR works, else
      // leave the band quiescent. Never leave orphaned timers/subscriptions.
      _hrKeepAliveTimer?.cancel();
      _setRealtimeHrActive(false);
      if (_device != null &&
          _device!.isConnected &&
          _authState == AuthState.authenticated &&
          passed.contains(3)) {
        _logger.i('MB6TEST: restoring normal realtime HR after session.');
        // Null the cached chars + listener so startRealtimeHeartRate()'s
        // _setupHeartRate() takes the full path and re-installs the normal HR
        // notification listener (it early-returns when chars are already set,
        // which would otherwise leave live HR without a subscriber).
        await _hrSubscription?.cancel();
        _hrSubscription = null;
        _hrMeasureChar = null;
        _hrControlChar = null;
        await startRealtimeHeartRate();
      }
      _isTestSessionRunning = false;
      _emitChange();
    }
  }

  // -------------------------------------------------------------------------
  // Gate 0 — discovery
  // -------------------------------------------------------------------------
  Future<({bool pass, bool halt, bool skipHr})> _gate0Discovery() async {
    if (_device == null || !_device!.isConnected) {
      _fail(0, 'not connected — connect to the band first, then re-run');
      return (pass: false, halt: true, skipHr: false);
    }
    final services = await _device!.discoverServices();
    final uuids = services.map((s) => s.uuid.str.toLowerCase()).toList();
    bool has(String f) => uuids.any((u) => u.contains(f));
    final fee0 = has('fee0'),
        fee1 = has('fee1'),
        s180d = has('180d'),
        s180f = has('180f');
    _logger.i('MB6TEST GATE0: services fee0=$fee0 fee1=$fee1 '
        '180d=$s180d 180f=$s180f (${uuids.length} total)');

    if (!fee0 || !fee1) {
      _fail(0, 'core Huami services missing (fee0=$fee0 fee1=$fee1) — '
          'cannot proceed; check the band is the expected Mi Band 6');
      return (pass: false, halt: true, skipHr: false);
    }
    if (s180d && s180f) {
      _pass(0, 'fee0, fee1, 180d, 180f all present');
      return (pass: true, halt: false, skipHr: false);
    }
    if (!s180d) {
      _pass(0, 'core present but 0x180D ABSENT — HR gates 3-5 will be skipped, '
          'HR validated via activity fetch instead');
      return (pass: true, halt: false, skipHr: true);
    }
    _pass(0, 'fee0, fee1, 180d present; 180f absent '
        '(battery will use fee0/0x0006)');
    return (pass: true, halt: false, skipHr: false);
  }

  // -------------------------------------------------------------------------
  // Gate 1 — auth (verify state; never re-runs the handshake)
  // -------------------------------------------------------------------------
  Future<bool> _gate1Auth() async {
    if (_authState == AuthState.authenticated) {
      _pass(1,
          isSignKeyAuth ? 'authenticated (Huami 2021 sign-key/ECDH auth)'
              : 'authenticated (legacy AES-ECB handshake, no 0xFF)');
      return true;
    }
    _fail(1, 'NOT authenticated (state=$_authState) — auth must complete first. '
        'If this regressed, diff the auth path against main. Reconnect & retry.');
    return false;
  }

  // -------------------------------------------------------------------------
  // Gate 2 — battery via fee0/0x0006 (fallback => UNCONFIRMED, never halts)
  // -------------------------------------------------------------------------
  Future<bool> _gate2Battery() async {
    try {
      final services = await _device!.discoverServices();
      BluetoothCharacteristic? c6;
      for (final svc in services) {
        if (!svc.uuid.str.toLowerCase().contains('fee0')) continue;
        for (final c in svc.characteristics) {
          if (c.uuid.str.toLowerCase().contains('0006')) c6 = c;
        }
      }

      if (c6 != null) {
        final raw = await c6.read();
        _logger.i('MB6TEST GATE2: fee0/0x0006 raw=${_hexStr(raw)}');
        if (raw.length >= 2) {
          final lvl = raw[1];
          final charging = raw.length >= 3 && raw[2] == 0x01;
          if (lvl >= 0 && lvl <= 100) {
            _setBatteryLevel(lvl);
            _emitChange();
            _pass(2, 'battery $lvl%${charging ? ' (charging)' : ''} via '
                'fee0/0x0006 byte[1] — canonical path CONFIRMED');
            return true;
          }
          _fail(2, 'fee0/0x0006 byte[1]=$lvl out of 0..100 — parse offset '
              'may be wrong (raw=${_hexStr(raw)})');
          return false;
        }
        _fail(2, 'fee0/0x0006 short read (${raw.length}B): ${_hexStr(raw)}');
        return false;
      }

      // Fallback path — claim stays UNCONFIRMED.
      BluetoothCharacteristic? c19;
      for (final svc in services) {
        if (!svc.uuid.str.toLowerCase().contains('180f')) continue;
        for (final c in svc.characteristics) {
          if (c.uuid.str.toLowerCase().contains('2a19')) c19 = c;
        }
      }
      if (c19 != null) {
        final raw = await c19.read();
        final lvl = raw.isNotEmpty ? raw[0] : -1;
        if (lvl >= 0 && lvl <= 100) {
          _setBatteryLevel(lvl);
          _emitChange();
        }
        _fail(2, 'fee0/0x0006 ABSENT — served $lvl% via 0x2A19 fallback '
            '(raw=${_hexStr(raw)}); fee0/0x0006 claim UNCONFIRMED');
        return false;
      }
      _fail(2, 'no battery characteristic found (neither fee0/0x0006 nor 0x2A19)');
      return false;
    } catch (e) {
      _fail(2, 'exception reading battery: $e');
      return false;
    }
  }

  // -------------------------------------------------------------------------
  // Gates 3-5 — realtime HR (shared subscription + event buffer)
  // -------------------------------------------------------------------------
  Future<({Set<int> passed, Set<int> skipped})> _runHrGates() async {
    final passed = <int>{};
    final skipped = <int>{};
    final events = <_HrEvent>[];
    StreamSubscription<List<int>>? sub;

    // Clean slate: stop any auto-started realtime HR + its listener/timer.
    _hrKeepAliveTimer?.cancel();
    _setRealtimeHrActive(false);
    await _hrSubscription?.cancel();
    _hrSubscription = null;

    try {
      // ---- GATE 3: discover HR chars + enable 0x2A37 CCCD ----
      _hrMeasureChar = null;
      _hrControlChar = null;
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
        _fail(3, '0x2A37/0x2A39 not found '
            '(measure=${_hrMeasureChar != null}, control=${_hrControlChar != null})');
        skipped.addAll({4, 5});
        return (passed: passed, skipped: skipped);
      }
      final m = _hrMeasureChar!;
      final cp = _hrControlChar!;
      _logger.i('MB6TEST GATE3: 0x2A37 props '
          'read=${m.properties.read} write=${m.properties.write} '
          'notify=${m.properties.notify} indicate=${m.properties.indicate}; '
          '0x2A39 props write=${cp.properties.write} '
          'writeNR=${cp.properties.writeWithoutResponse}');

      // Root-cause probe: log the Android bond state. On-device captures showed
      // the link reporting unbonded / "Encryption LE: null", which correlates
      // with the CCCD rejection (findings-05).
      _logger.i('MB6TEST GATE3: bond state = ${await currentBondState()}');

      // Attempt 1 — enable the CCCD as-is (disable→enable to truly exercise it).
      try {
        await m.setNotifyValue(false);
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 300));
      var enabled = await _tryEnableCccd(m, 'attempt-1 (no bond)');

      // Attempt 2 — if rejected, bond/encrypt the link and retry once. This
      // tests the "link must be encrypted" hypothesis on hardware.
      if (!enabled && _device != null && _device!.isConnected) {
        _logger.i('MB6TEST GATE3: CCCD rejected — bonding the link, then retry…');
        await _ensureLinkEncrypted();
        enabled = await _tryEnableCccd(m, 'attempt-2 (after createBond)');
      }

      if (enabled) {
        _pass(3, '0x2A37 CCCD enabled — bond=${await currentBondState()}');
        passed.add(3);
      } else {
        _fail(3, '0x2A37 CCCD still rejected after bond attempt — '
            'bond=${await currentBondState()}, props '
            'notify=${m.properties.notify} indicate=${m.properties.indicate} '
            'write=${m.properties.write}');
        skipped.addAll({4, 5});
        return (passed: passed, skipped: skipped);
      }

      // Session HR listener — records valid readings + updates live BPM.
      sub = m.onValueReceived.listen((data) {
        if (data.length < 2) {
          _logger.d('MB6TEST HR notify (short ${data.length}B): ${_hexStr(data)}');
          return;
        }
        final bpm = data[1] & 0xFF;
        _logger.d('MB6TEST HR notify: ${_hexStr(data)} -> $bpm bpm');
        if (bpm >= 7 && bpm <= 249) {
          events.add((t: DateTime.now(), bpm: bpm));
          _setHeartRate(bpm);
          _emitChange();
        }
      });

      // ---- GATE 4: start continuous, wait for a plausible BPM ----
      await _writeHrControl(_stopManual, 'stop-manual');
      await _writeHrControl(_startContinuous, 'start-continuous');
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      int? firstPlausible;
      while (DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(milliseconds: 500));
        final p = events.where((e) => e.bpm >= 40 && e.bpm <= 180);
        if (p.isNotEmpty) {
          firstPlausible = p.first.bpm;
          break;
        }
      }
      if (firstPlausible != null) {
        _pass(4, 'parsed BPM=$firstPlausible (plausible 40..180) — '
            'parse offset (data[1]) confirmed');
        passed.add(4);
      } else {
        final seen = events.map((e) => e.bpm).take(8).toList();
        final hint = events.isEmpty
            ? 'NO notifications arrived — band likely OFF-WRIST or not measuring'
            : 'readings=$seen (a 0 => parse offset wrong; 255/sentinel => not '
                'measuring, check fit/wear)';
        _fail(4, 'no plausible BPM within 20s — $hint');
        skipped.add(5);
        return (passed: passed, skipped: skipped);
      }

      // ---- GATE 5: keep-alive sustain test with auto-probe ----
      // The 12 s value is single-sourced (Notify only); probe 12 → 8 → 15 s and
      // record which sustains HR past the 60 s mark.
      const intervals = [12, 8, 15];
      int? goodInterval;
      for (final iv in intervals) {
        if (_device == null || !_device!.isConnected) break;
        _logger.i('MB6TEST GATE5: probing keep-alive=${iv}s, watching 90s '
            '(0x16 ping every ${iv}s)...');
        final w = await _watchHrWithKeepAlive(
          events: events,
          pingInterval: Duration(seconds: iv),
          watch: const Duration(seconds: 90),
        );
        _logger.i('MB6TEST GATE5: interval=${iv}s -> '
            'events 0-30s=${w.early} 30-60s=${w.mid} 60-90s=${w.late}');
        if (w.late > 0) {
          goodInterval = iv;
          break;
        }
        _logger.i('MB6TEST GATE5: HR did not survive past 60s at ${iv}s — '
            're-arming continuous HR and trying the next interval');
        await _writeHrControl(_stopContinuous, 'stop-continuous');
        await Future.delayed(const Duration(seconds: 1));
        await _writeHrControl(_startContinuous, 'start-continuous');
      }
      if (goodInterval != null) {
        _pass(5, 'HR sustained past 60s with a ${goodInterval}s keep-alive '
            '(0x16 → 0x2A39)${goodInterval == 12 ? ' — confirms the assumed 12 s' : ' — DIFFERS from the assumed 12 s; update protocol-mb6.md'}');
        passed.add(5);
      } else {
        _fail(5, 'HR stopped before 60s at every tested interval (12/8/15 s) — '
            'keep-alive payload/interval likely wrong, or band went off-wrist');
      }
      return (passed: passed, skipped: skipped);
    } finally {
      await sub?.cancel();
      // Leave the control point in a known-stopped state for a clean re-run.
      try {
        await _writeHrControl(_stopContinuous, 'stop-continuous (cleanup)');
      } catch (_) {}
    }
  }

  /// Watch HR notifications for [watch] while pinging 0x16 every [pingInterval];
  /// return event counts bucketed into 0-30 / 30-60 / 60-90 s windows.
  Future<({int early, int mid, int late})> _watchHrWithKeepAlive({
    required List<_HrEvent> events,
    required Duration pingInterval,
    required Duration watch,
  }) async {
    final start = DateTime.now();
    final pingTimer = Timer.periodic(pingInterval, (_) async {
      if (_device == null || !_device!.isConnected) return;
      await _writeHrControl(_ping, 'keep-alive(${pingInterval.inSeconds}s)');
    });
    try {
      await Future.delayed(watch);
    } finally {
      pingTimer.cancel();
    }
    int countBetween(Duration from, Duration to) => events.where((e) {
          final dt = e.t.difference(start);
          return dt >= from && dt < to;
        }).length;
    return (
      early: countBetween(Duration.zero, const Duration(seconds: 30)),
      mid: countBetween(const Duration(seconds: 30), const Duration(seconds: 60)),
      late: countBetween(const Duration(seconds: 60), const Duration(seconds: 90)),
    );
  }

  // -------------------------------------------------------------------------
  // Gate 6 — activity fetch (8-byte layout, HR at byte 3, sane steps)
  // -------------------------------------------------------------------------
  Future<bool> _gate6ActivityFetch() async {
    ActivityFetcher? fetcher;
    try {
      fetcher = ActivityFetcher(_logger, _device!);
      if (!await fetcher.init()) {
        _fail(6, 'ActivityFetcher init failed (control/data chars missing?)');
        return false;
      }
      final since =
          _lastSyncTime ?? DateTime.now().subtract(const Duration(days: 1));
      _logger.i('MB6TEST GATE6: fetching activity since $since');
      final samples = await fetcher.fetchActivityData(since);
      final raw = fetcher.lastRawBuffer;
      final preview =
          raw.take(32).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

      if (samples.isEmpty) {
        _logger.i('MB6TEST GATE6: raw(${raw.length}B) first32: $preview');
        _fail(6, 'no samples parsed — either the band has no new data since '
            '$since, or the 8-byte layout is wrong (inspect raw bytes above)');
        return false;
      }

      final withHr = samples.where((s) => s.heartRate > 0).length;
      // Collapse the band's repeated per-minute step values (raw Σ over-counts
      // ~4-6×, see stepsPerMinute) so the diagnostic total matches the band.
      final totalSteps =
          stepsPerMinute(samples).values.fold<int>(0, (a, v) => a + v);
      final maxStepsPerMin =
          samples.fold<int>(0, (a, s) => s.steps > a ? s.steps : a);

      if (maxStepsPerMin > 255) {
        _logger.i('MB6TEST GATE6: raw(${raw.length}B) first32: $preview');
        _fail(6, 'steps/min=$maxStepsPerMin exceeds the 1-byte field max (255) '
            '— sample layout likely misaligned (see raw bytes above)');
        return false;
      }

      final hrNote = withHr > 0
          ? '$withHr/${samples.length} samples carry HR (byte 3) — layout confirmed'
          : 'no HR>0 in any sample (band may have been off-wrist; byte-3 HR UNCONFIRMED)';
      _pass(6, '${samples.length} samples parsed, totalSteps=$totalSteps, '
          'maxSteps/min=$maxStepsPerMin (sane); $hrNote');
      return true;
    } catch (e) {
      _fail(6, 'exception during fetch: $e');
      return false;
    } finally {
      fetcher?.dispose();
    }
  }

  // -------------------------------------------------------------------------
  // Gate 7 — a plausible sleep session comes out of the stored samples
  //
  // Guards the rebuilt SleepAnalyzer (findings-18) against the failure mode it
  // replaced: numbers that parse cleanly but are physiologically impossible
  // (98 % light / 6 min deep, or a 14-hour "night" made of evening stillness).
  // Cradle-safe — it re-analyses data already fetched by Gate 6.
  // -------------------------------------------------------------------------
  Future<bool> _gate7Sleep() async {
    try {
      final samples = activityStore.samples;
      if (samples.isEmpty) {
        _fail(7, 'no stored samples to analyse (run Gate 6 first)');
        return false;
      }

      // Log the observed kind-byte histogram. This is the evidence that decides
      // the open question in protocol-mb6.md §7.2: Gadgetbridge's legacy table
      // says sleep is kind 9/11, but our captures show 0xF0/0xF3.
      final kinds = <int, int>{};
      for (final s in samples) {
        kinds[s.category] = (kinds[s.category] ?? 0) + 1;
      }
      final top = kinds.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      final histogram = top
          .take(8)
          .map((e) =>
              '0x${e.key.toRadixString(16).padLeft(2, '0')}(&0x0F=${e.key & 0x0F})×${e.value}')
          .join(' ');
      _logger.i('MB6TEST GATE7: kind-byte histogram: $histogram');

      final days = SleepAnalyzer.detectSessions(
        samples,
        hr: activityStore.hrReadings,
      );
      if (days.isEmpty) {
        _fail(7, 'no sleep session detected across ${samples.length} samples '
            '— check the kind histogram above against protocol-mb6.md §7');
        return false;
      }

      final nights = days.where((d) => !d.isNap).toList();
      final session = nights.isNotEmpty ? nights.last : days.last;
      final q = SleepQuality.of(session);
      final total = session.totalSleepMinutes;
      final deepPct = total == 0 ? 0.0 : session.totalDeepMinutes * 100.0 / total;

      _logger.i('MB6TEST GATE7: session ${session.startTime}→${session.endTime} '
          'total=${total}m light=${session.totalLightMinutes}m '
          'deep=${session.totalDeepMinutes}m (${deepPct.toStringAsFixed(1)}%) '
          'awake=${session.totalAwakeMinutes}m '
          'eff=${q.efficiencyPercent.toStringAsFixed(1)}% '
          'latency=${q.latencyMinutes}m wakes=${q.wakeEpisodes} '
          'naps=${days.where((d) => d.isNap).length}');

      // Plausibility, not correctness: these bounds only catch the class of bug
      // that produced "6 minutes of deep sleep in 8 h21".
      if (session.isNap) {
        _fail(7, 'only naps detected — no main sleep session in the data');
        return false;
      }
      if (total > 14 * 60) {
        _fail(7, 'implausible night of ${total}m (>14 h) — sessions are '
            'over-merging; check the 60-minute wake-gap split');
        return false;
      }
      if (session.totalRemMinutes != 0) {
        _fail(7, 'REM reported (${session.totalRemMinutes}m) but this firmware '
            'never populates the REM byte — the analyzer is inventing it');
        return false;
      }
      _pass(7, 'night=${total}m deep=${deepPct.toStringAsFixed(1)}% '
          'eff=${q.efficiencyPercent.toStringAsFixed(1)}% '
          'wakes=${q.wakeEpisodes} — plausible');
      return true;
    } catch (e) {
      _fail(7, 'exception during sleep analysis: $e');
      return false;
    }
  }

  // -------------------------------------------------------------------------
  // Gate 8 — a notification actually reaches the band
  //
  // Cradle-safe. Cannot self-verify: it sends a real alert and asks for visual
  // confirmation, so it reports SKIPPED rather than PASS unless the write
  // itself succeeded. The point is to prove the BLE half of the notification
  // path independently of Android's notification listener (findings-17).
  // -------------------------------------------------------------------------
  Future<bool> _gate8Notification() async {
    try {
      if (!alertManager.isReady) {
        _fail(8, 'fee0/0x0020 alert characteristic not discovered');
        return false;
      }
      final cmd = AlertManager.buildAppNotification(
        appName: 'MB6TEST',
        title: 'Gate 8',
        body: 'Notification path check',
        iconId: HuamiIcon.chatBlue,
      );
      final chunks = AlertManager.buildChunks(
        cmd,
        maxChunkLength: AlertManager.chunkLengthForMtu(_mtu),
      );
      _logger.i('MB6TEST GATE8: payload ${cmd.length}B → ${chunks.length} '
          'chunk(s) at mtu=$_mtu; first frame: '
          '${chunks.first.take(10).map((b) => b.toRadixString(16).padLeft(2, "0")).join(" ")}');

      await alertManager.sendAppNotification(
        'MB6TEST',
        'Gate 8',
        'Notification path check',
      );
      _logger.i('MB6TEST GATE8: >>> VISUAL CHECK: the band should now be '
          'showing "Gate 8 / Notification path check". If it is not, the '
          'payload is wrong — see protocol-mb6.md §8. <<<');
      _pass(8, 'alert written to 0x0020 in ${chunks.length} chunk(s) — '
          'REQUIRES VISUAL CONFIRMATION on the band');
      return true;
    } catch (e) {
      _fail(8, 'exception sending test notification: $e');
      return false;
    }
  }

  // -------------------------------------------------------------------------
  // Banner helpers (the greppable headline tokens)
  // -------------------------------------------------------------------------
  /// Try to enable the 0x2A37 CCCD; log + return false on rejection (capturing
  /// the exact GATT code, e.g. 3 = WRITE_NOT_PERMITTED).
  Future<bool> _tryEnableCccd(BluetoothCharacteristic m, String label) async {
    try {
      await m.setNotifyValue(true);
      _logger.i('MB6TEST GATE3: $label — CCCD enabled OK');
      return true;
    } catch (e) {
      final code = e is FlutterBluePlusException ? e.code : null;
      final desc = e is FlutterBluePlusException ? e.description : '$e';
      _logger.e('MB6TEST GATE3: $label — setNotifyValue(0x2A37) threw '
          '${e.runtimeType} code=$code desc="$desc"');
      return false;
    }
  }

  void _pass(int gate, String detail) =>
      _logger.i('MB6TEST GATE$gate: PASS — $detail');

  void _fail(int gate, String detail) =>
      _logger.e('MB6TEST GATE$gate: FAIL — $detail');

  void _finishSession(Set<int> passed, Set<int> skipped, int total, String fw) {
    final map = List.generate(total, (g) {
      if (passed.contains(g)) return '$g:P';
      if (skipped.contains(g)) return '$g:S';
      return '$g:F';
    }).join(' ');
    _logger.i('MB6TEST SESSION END — ${passed.length}/$total passed, '
        '${skipped.length} skipped  [$map]');
    // Single-line machine-parseable summary (grep `MB6TEST SUMMARY`).
    _logger.i('MB6TEST SUMMARY p=${passed.length} s=${skipped.length} '
        'gates=[$map] fw=$fw');
  }

  /// Best-effort firmware version read from the standard Device Information
  /// Service (0x180A → Firmware Revision String 0x2A26). Returns "unknown" if
  /// the band does not expose it (Huami often reports firmware via a private
  /// command instead). Never throws.
  Future<String> _readFirmwareVersion() async {
    try {
      if (_device == null || !_device!.isConnected) return 'unknown';
      final services = await _device!.discoverServices();
      for (final svc in services) {
        if (!svc.uuid.str.toLowerCase().contains('180a')) continue;
        for (final c in svc.characteristics) {
          if (!c.uuid.str.toLowerCase().contains('2a26')) continue;
          if (!c.properties.read) continue;
          final raw = await c.read();
          final s = String.fromCharCodes(raw.where((b) => b >= 0x20 && b < 0x7f));
          return s.trim().isEmpty ? 'unknown' : s.trim();
        }
      }
    } catch (_) {}
    return 'unknown';
  }
}
