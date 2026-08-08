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
