# findings-16 — Background connection: supervision, backoff, liveness

**Date:** 2026-08-09
**Scope:** connection management, foreground service and Android background
permissions. **No protocol bytes changed**; the sign-key (ECDH) auth path is
untouched and its unit tests still pass. `flutter analyze` clean;
`flutter test` 87/87.

> Hardware note: no adb device was attached this session, so **none** of this is
> hardware-verified. The eight checks that matter (airplane mode, out of range,
> band reboot, half-open link, task removal, phone reboot, permissions, timing)
> are queued as §P4 in `pending-hardware-verification.md`.

---

## 1. What was wrong

`foreground_task_handler.dart` was a no-op, and reconnection was this:

```dart
void _scheduleReconnect() {
  _reconnectTimer = Timer(const Duration(seconds: 3), () async {
    try { await _device!.connect(autoConnect: false); }
    catch (e) { _reconnectTimer = Timer(const Duration(seconds: 5), _scheduleReconnect); }
  });
}
```

Concrete consequences:

1. **No backoff.** A band out of range was retried every 3–5 s indefinitely,
   burning battery on a radio operation that could not succeed.
2. **No adapter awareness.** With Bluetooth off, every attempt failed
   immediately, so the loop ran as fast as the stack could reject it.
3. **No liveness detection.** BLE's most annoying failure is the *half-open*
   link: GATT still reports `connected`, but no notification ever arrives again.
   Nothing in the app could detect or recover from this.
4. **The service was stopped during reconnect.** `_handleDisconnect()` called
   `_stopForegroundService()` *before* scheduling the retry — so during exactly
   the window where the process needed protection, it had none. Android could
   reclaim it, and the band would then stay disconnected until the user
   reopened the app.
5. **Intent was not persisted.** "Should we be connected?" was inferred from
   whether a MAC happened to be stored. There was no way to distinguish
   "paired, temporarily disconnected" from "user deliberately disconnected".
6. **State was four disagreeing booleans** — `isConnected`, `isAuthenticating`,
   `isReconnecting`, `authState` — with no single answer to "what is happening?".
7. **HR streaming was force-enabled on every auth.** `_onAuthSuccess()`
   unconditionally called `startRealtimeHeartRate()`, so a user who turned
   streaming off got it switched back on by any reconnect.
8. **Dead code:** `lib/core/foreground_task_handler.dart` declared a *second*
   `@pragma('vm:entry-point') startCallback` that nothing referenced (the live
   one is in `ble_manager.dart`). Deleted.

## 2. The supervisor

`lib/core/connection_supervisor.dart` (a `part` of `ble_manager.dart`, matching
the existing `hardware_test_session.dart` / `huami2021_auth.dart` convention).

### 2.1 One explicit state

```
idle · bluetoothOff · scanning · connecting · authenticating · ready · waitingToRetry
```

`ConnectionPhase` is exposed as `connectionPhaseListenable` and carries a
human-readable `.label` used by both the status chip and the persistent
notification — never a raw exception string.

`_setAuthState()` drives the phase, so authentication state and connection phase
cannot disagree.

### 2.2 Backoff — `lib/core/reconnect_backoff.dart`

Deliberately a **plain class, not a private helper**, so the policy is
unit-testable without a BLE stack:

| Attempt | 1 | 2 | 3 | 4 | 5 | 6+ |
|---|---|---|---|---|---|---|
| Delay | 1 s | 2 s | 5 s | 15 s | 30 s | 60 s (cap) |

- ±20 % jitter so several clients (or a reconnect storm after an adapter toggle)
  do not retry in lockstep.
- Retries **indefinitely** while the user wants to be connected.
- `reset()` on a successful link, so a later unrelated drop starts at 1 s rather
  than inheriting a 60 s penalty.
- Clamped to stay strictly positive even at maximum negative jitter.

### 2.3 Adapter awareness

`FlutterBluePlus.adapterState` is watched. On **off** → cancel the pending retry
and park in `bluetoothOff` (no attempts at all). On **off→on** → `reset()` the
backoff and reconnect immediately: the previous failures were caused by the
radio being off, so serving out the accumulated penalty would be wrong.
`_attemptConnect` also re-checks the adapter before burning an attempt.

### 2.4 Liveness heartbeat

Every inbound path (`_handleAuthResponse`, `_applyStepsPacket`,
`_onHeartRateNotified`, `_applyHuamiBattery`, and connect itself) calls
`_markPacket()`. A 1-minute timer checks the deadline: **5 minutes of total
silence while nominally connected** ⇒ tear the link down and let the normal
reconnect path rebuild it.

Five minutes is chosen against known traffic: battery/steps notifications arrive
well inside it, and the 12 s HR keep-alive provokes traffic whenever streaming
is on. The same timer also restarts the loop if a retry timer was lost across a
process freeze.

### 2.5 Persisted intent

`StorageManager.setWantsConnected()` / `getWantsConnected()`. Reading defaults to
"true when a device MAC exists", so bands paired before this flag existed keep
working. `startSupervision()` sets it; `disconnect()` clears it. This is what
makes `autoRunOnBoot` safe — the service can come back after a reboot and still
respect a user who deliberately disconnected.

### 2.6 Service correctness

- Foreground service **stays up during reconnect** (fix for §1.4); it is only
  stopped on an explicit user disconnect.
- Notification body is now `state · battery · synced Nm ago`, refreshed on
  battery updates and phase changes.
- `autoRunOnBoot: true` + `autoRunOnMyPackageReplaced: true`.
- Manifest gains `POST_NOTIFICATIONS` (Android 13+ — without it the service runs
  but shows nothing, which also makes it likelier to be reclaimed),
  `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` and `RECEIVE_BOOT_COMPLETED`.
- `background_permissions.dart` checks/requests both, and **does not prompt on
  its own** for the Doze exemption: that is a system dialog that reads as
  alarming without context, so the caller explains first. Declining is a valid
  choice and degrades to foreground-only rather than nagging.
- `foregroundServiceType="connectedDevice"` was already correct in the manifest.

### 2.7 Re-auth restores state, not defaults

`_onAuthSuccess()` re-applies band settings on **every** connect (the band loses
some across a reset; Gadgetbridge does the same rather than configuring only at
pair time) and re-arms HR streaming **only if `_userWantsHrStreaming`**.

---

## 3. Verified here

| Claim | Evidence |
|---|---|
| Schedule is 1/2/5/15/30/60 s | `test/reconnect_backoff_test.dart` |
| Cap holds and retries forever | 100 further attempts all 60 s |
| Jitter within ±20 % | tested at both jitter extremes |
| Delay always positive | max-negative-jitter test |
| `reset()` returns to 1 s | reset test |
| Auth path unaffected | `ecdh_b163_test`, `huami2021_chunked_test` green |

## 4. Reconnect timing — TO BE MEASURED

Fill from §P4 of `pending-hardware-verification.md`:

| Scenario | disconnect → ready | Notes |
|---|---|---|
| Airplane mode off→on | _pending_ | expect ~1 s after adapter ON |
| Walk back into range | _pending_ | depends where in the schedule it lands |
| Band reboot | _pending_ | includes full sign-key re-auth |
| Half-open link | _pending_ | detection ≤6 min, then normal reconnect |

## 5. Honest limits

- The 5-minute liveness window is reasoned from known traffic, not measured. If
  P4.4 shows the band legitimately goes quiet for longer while idle, this will
  produce spurious reconnects and the constant must be raised.
- `ConnectionPhase.scanning` is defined but unused: we always connect directly
  by MAC. It is kept for the case where a MAC-less connect path is added.
- `autoRunOnBoot` depends on the plugin's boot receiver; P4.6 is the check that
  it actually fires on this device, since OEM Android builds vary.
- No boot-receiver *setting* is exposed yet — Phase 3/7 will surface it in
  Settings → Advanced alongside the battery-exemption explanation screen.
