# Pending hardware verification

Steps that need the physical Mi Band 6 (and/or an attached Android device) and
could **not** be run in the session that introduced them. Nothing in this file
should be treated as verified. When a device is available, work top-down and
record results in the next free `test-results-NN.md`.

## Session context (2026-08-09)

`adb devices` was **empty** for the whole session and no Android device was
present on USB (`lsusb` showed only keyboard / Bluetooth radio / webcam). The
previously used device was a Pixel 9a, serial `55211XEBF1RB28`
(see `capture-logs.md`). A watcher was left armed that applies the keep-awake
settings automatically the moment a device reappears:

```bash
adb shell svc power stayon true
adb shell settings put global stay_on_while_plugged_in 7
adb shell dumpsys deviceidle whitelist +com.example.band
adb shell cmd appops set com.example.band RUN_IN_BACKGROUND allow
```

Re-run those by hand if the watcher is no longer running.

---

## P1 — Performance (findings-15)

- [ ] **P1.1 Profile-mode frame capture.** `flutter run --profile`, open each
      tab, scroll continuously for 30 s **with realtime HR streaming ON**.
      Record dropped/janky frame counts and worst frame time per tab, before vs
      after. Fill the before/after table in `findings-15.md` §3.
      - Target: zero dropped frames while scrolling with HR streaming.
- [ ] **P1.2 Confirm the heartbeat no longer rebuilds Sleep/Activity.** With
      verbose logging ON, stream HR while sitting on the Sleep tab and confirm
      no rebuild-driven work appears; `debugProfileBuildsEnabled` or a temporary
      build counter is the cheapest check.
- [ ] **P1.3 Connect-time improvement.** Time `connect → authenticated → first
      metrics` before/after the service-discovery cache (§2.8). Expect a
      noticeable drop; the old path did ~9 full GATT discoveries.
- [ ] **P1.4 Debounced writes survive process death.** Walk (to generate steps
      notifies), then force-stop the app within the 5 s metrics debounce window
      and confirm no more than the last window of metrics is lost, and that a
      disconnect flushes (`_flushPendingWrites`).
- [ ] **P1.5 Isolate-encoded save.** Confirm `compute()`-based
      `ActivityStore.save()` works on-device with a multi-day history (isolate
      spawn is cheap but not free) and that no data is lost across a restart.

## P0 — Environment

- [ ] **P0.1** Re-confirm the gated hardware session still passes end-to-end
      after the Phase-1 refactor: expect
      `MB6TEST SUMMARY p=7 s=0 gates=[0:P 1:P 2:P 3:P 4:P 5:P 6:P]`.
      This is the regression gate for "the BLE layer still works" and must be
      run before trusting any later phase's hardware results.

---

## Wrist-required vs cradle-safe

Steps needing the band **worn** (HR, stress, sleep) cannot be validated
overnight with the band on a charger — a desk band reads 0 BPM. Split any run:

- **Cradle-safe:** connection/auth, battery, settings writes + read-back,
  notification delivery, fetch of *previously recorded* history.
- **Wrist-required:** realtime HR values, stress samples, a real sleep session.

---

## P4 — Background connection (findings-16)

- [ ] **P4.1 Airplane-mode toggle.** Enable airplane mode for 60 s, disable.
      Expect: phase → `bluetoothOff` (no retry storm in the log), then on adapter
      ON a single `Supervisor: Bluetooth adapter ON` followed by a reconnect
      **at the bottom of the backoff** (1 s), not the 60 s cap.
- [ ] **P4.2 Walk out of range.** Leave range for ~10 min. Expect the logged
      retry deltas to follow 1 → 2 → 5 → 15 → 30 → 60 s and then hold at 60 s.
      Record the observed reconnect time once back in range.
- [ ] **P4.3 Band reboot.** Reboot the band; confirm re-auth runs the full
      sign-key flow, settings are re-applied, and HR streaming returns **only if
      it was on before** (`_userWantsHrStreaming`).
- [ ] **P4.4 Half-open link.** Hardest to force: block traffic without a GATT
      disconnect (e.g. band in a metal enclosure). Expect
      `no packet for N min while connected — forcing a reconnect cycle` within
      6 min, then a normal reconnect.
- [ ] **P4.5 Task removal.** Swipe the app from recents while connected.
      Expect the foreground service to survive and the notification to keep
      updating (state · battery · last sync).
- [ ] **P4.6 Phone reboot.** With `autoRunOnBoot: true`, confirm the service
      returns after a reboot and reconnects **only** when the persisted
      "wants connected" intent is true. Verify that a user who explicitly
      disconnected stays disconnected across a reboot.
- [ ] **P4.7 Permissions.** On Android 13+, confirm POST_NOTIFICATIONS is
      requested at first connect and the persistent notification actually
      appears; confirm the battery-optimization exemption flow opens the system
      dialog and that declining degrades gracefully (no nagging loop).
- [ ] **P4.8 Reconnect timing table.** Record observed
      `disconnect → ready` times for P4.1–P4.3 and fill the table in
      `findings-16.md` §4.
