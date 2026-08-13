# Pending hardware verification

## Ledger — verified vs not

### ✅ VERIFIED ON HARDWARE 2026-08-10 (Pixel 9a + band worn overnight)

- `2021 SIGN-KEY AUTHENTICATION SUCCESS` — auth path intact after the whole
  2026-08-09 overhaul. This was the main regression risk and it is clear.
- MTU negotiated **247**; ANS `0x2A46` discovered for call alerts.
- **Connection supervisor backoff observed live**: retry #1 at 0.8 s, #2 at
  1.8 s, then connected — the jittered 1→2 s schedule, working (P4 partial).
- **Every band configuration command accepted** (P3.1), including
  `FE 06 00 01` (all-day stress), `14 01` (1-minute HR interval),
  `15 00 01` (sleep-assisted HR), `06 22 00 01` (all-day HR).
- **Protocol §7.2 settled** (P2.1) — see findings-21. The kind byte is two
  independent nibbles; 60 404 real samples decided it.
- Realtime-streaming intent survives a force-stop + relaunch.
- Warm engine starts and the app reconnects on launch.

### 🐞 FOUND ON HARDWARE, FIXED
- `_userWantsHrStreaming` was not persisted, so any restart silently resumed the
  1 Hz stream. At 28 % battery that would have flattened the band in ~3 h and
  lost the night. Now persisted; verified across a restart.
- The warm engine broke the cold-launch intent trigger (Dart polled before
  MainActivity attached). MainActivity now pushes the trigger.
- Sleep pipeline: three defects, all quantified against real data (findings-21).

### ⏳ STILL NOT VERIFIED
| Area | What would prove it |
|---|---|
| Notifications (findings-17) | **P5.2** post-swipe delivery. Gate 8 was deliberately NOT run overnight — it buzzes the band and the user was asleep. |
| Sleep accuracy | **P2.3** minute-by-minute vs Zepp Life / Sleep as Android for the same night. Still the only real accuracy check. |
| HR interval effect | **P3.2** — that 1-min periodic HR actually changes sample cadence in the next fetch. Tonight's capture is the test. |
| Stress data | **P6.1-P6.4** — all-day stress was only enabled at 02:02, so the first real stress records arrive with tonight's night. |
| ~~Dark mode~~ | **P7.1/P7.2 done 2026-08-12** — and the pass paid for itself: a solid-white card, near-invisible headings and unreadable "on" switches, all found by looking. See findings-22. |
| Deep-sleep front-loading | Unresolved; needs polysomnography, not more tuning. |

---

### Verified on hardware (earlier sessions, unchanged by this work)
- Sign-key (ECDH) authentication — `test-results-01.md`, all 7 gates passed
- Realtime heart rate via `0x2A37`/`0x2A39` + the 12 s keep-alive
- Battery via `fee0/0x0006`
- Activity fetch, 8-byte sample layout, HR at byte 3
- SpO2 (`0x25`) record layout — hand-decoded from real bytes (findings-08)
- `0x48` sleep-session fetch returns **zero** records on this band (findings-09)
- Overnight snoring detection (findings-10)

### Implemented this session — NOT verified on hardware
| Area | Evidence it is *probably* right | What would prove it |
|---|---|---|
| Performance (findings-15) | 19 unit tests; O(n)-per-heartbeat work removed | P1.1 profile capture |
| Connection supervisor (16) | 7 backoff tests; state machine | P4.1-P4.8 |
| Notifications (17) | 14 byte-level tests vs GB + Notify; APK builds | **P5.2** (post-swipe delivery) |
| Sleep analyzer (18) | 25 tests incl. every edge case named in the brief | **P2.3** (vs Zepp Life) |
| Band settings (19) | 32 tests pinning bytes *and* target characteristic | **P3.2** (cadence actually changes) |
| Stress (20) | 28 tests; layouts from GB + Notify + Mi Fit | P6.1-P6.4 |
| Light/dark theme | contrast enforced by test, 8 real light-theme failures fixed | **P7.1/P7.2 verified 2026-08-12** (findings-22) |

### Established as *not possible* on this firmware
- **HRV / recovery** — 34/34 captured `0x2A37` packets are 2 bytes with flags
  `0x00` (RR bit clear); `0x49` is ZeppOS-gated. P6.5 is the probe that could
  overturn this.
- **REM sleep** — the REM byte is identically 0; Gate 7 fails if it is reported.
- **Sleep-session stream `0x48`** — probed, band returned length 0.
- **SpO2 all-day / sleep-breathing toggles** — ZeppOS-only config items.

### Open protocol contradiction
`protocol-mb6.md` §7.2: Gadgetbridge's legacy table says sleep is kind **9/11**;
our captures show **0xF0/0xF3**. The analyzer honours both. **Gate 7 logs the
kind-byte histogram — one run settles it (P2.1).**

---

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

---

## P2 — Sleep accuracy (findings-18)

- [ ] **P2.1 Kind-byte histogram (decides an open protocol question).**
      Run the gated session and read the `MB6TEST GATE7: kind-byte histogram`
      line. Gadgetbridge's legacy table says sleep is kind **9/11**; our capture
      showed **0xF0/0xF3** overnight and **0x50** daytime. Record the real
      distribution and settle `protocol-mb6.md` §7.2 — then either confirm the
      `sleep`-byte gate or switch to the kind values.
- [ ] **P2.2 Gate 7 passes on a real night.** Expect a plausible session:
      total ≤14 h, deep 10-25 %, REM exactly 0, efficiency ≤100 %.
- [ ] **P2.3 Minute-by-minute comparison vs Zepp Life / Mi Fit** for the same
      night: bedtime, wake time, total, deep, light, awake, wake episodes.
      Log the table in `test-results-02.md`. This is the only real accuracy
      check — the unit tests only prove internal consistency.
- [ ] **P2.4 Not-worn rejection.** Leave the band on a desk overnight; expect
      **no** sleep session (previously this produced a perfect night).
- [ ] **P2.5 Nap.** Take a ≤90 min daytime sleep; expect exactly one nap
      session, `isNap == true`, and no contribution to the night's totals.
- [ ] **P2.6 Old vs new on the same data.** `computeSleepDaysLegacy()` is kept
      for exactly this: run both over one captured `activity_data.json` and put
      the deltas in `test-results-02.md`.

## P5 — Notifications (findings-17)

- [ ] **P5.1 Gate 8 visual check.** Run the gated session; the band must show
      "Gate 8 / Notification path check". If the write succeeds but nothing
      appears, the payload is still wrong — compare against `protocol-mb6.md` §8.
- [ ] **P5.2 Warm-engine survival (the actual bug).** Grant notification access,
      enable relay for one app, then **swipe the app from recents**. Post a
      notification from that app. It must still reach the band. Previously this
      was the exact case that failed silently.
- [ ] **P5.3 Chat apps.** Verify a WhatsApp/Signal/Telegram message arrives with
      real text (the `MessagingStyle` fix), not blank.
- [ ] **P5.4 Long text chunking.** Send a >250-character notification and
      confirm it is not truncated mid-word and does not fail; check the log for
      `in N chunk(s)` with N > 1.
- [ ] **P5.5 Incoming call.** Confirm the call alert appears via `0x2A46`
      (`[03 01]+caller`) and clears on hang-up (`[03 00]`).
- [ ] **P5.6 Dedup / privacy / screen-on.** Re-post the same notification twice
      inside 30 s (one buzz only); enable privacy mode (title only, no body);
      enable skip-while-screen-on and confirm it suppresses.
- [ ] **P5.7 Icons.** Check WhatsApp shows the WhatsApp glyph and an unknown app
      shows the generic one (id 11).
- [ ] **P5.8 Listener rebind.** Reinstall/update the APK and confirm the relay
      recovers without the user toggling notification access.

---

## P3 — Band settings (findings-19)

- [ ] **P3.1 Gate 9 passes.** All config writes accepted (no rejection lines).
      A rejection means a wrong target characteristic — see `protocol-mb6.md` §9.
- [ ] **P3.2 HR interval takes effect (the only externally observable proof).**
      Set to 1 min, wear the band ~15 min, fetch, and confirm per-minute HR
      samples appear at that cadence. Repeat at 5 min and confirm the cadence
      changes. **A successful GATT write proves nothing on its own** — the band
      accepts and ignores commands it does not understand.
- [ ] **P3.3 Visible settings on the band.** Change time format, units and
      lift-wrist and confirm each on the band's own UI.
- [ ] **P3.4 Re-apply after reconnect.** Change several settings, force a
      disconnect/reconnect, and confirm they are re-sent (`BandConfig:
      re-applying all settings (post-auth)`) and still correct on the band.
- [ ] **P3.5 Rollback.** Force a write failure (e.g. toggle while
      disconnecting) and confirm the switch flips back with an explanation
      rather than silently claiming success.
- [ ] **P3.6 Stress toggle actually enables recording.** Turn on all-day stress,
      wear for a few hours, then confirm the stress fetch (Phase 6) returns
      samples where it previously returned none.

---

## P6 — Stress (findings-20)

- [ ] **P6.1 Gate 10.** Enable all-day stress, wear the band a few hours, run the
      session. Expect all-day + manual readings, all within 0..100.
      SKIPPED (no records) means monitoring was off, not a protocol bug.
- [ ] **P6.2 All-day toggle really enables recording.** Confirm the fetch
      returns nothing with the toggle off and data with it on — this is what
      proves `FE 06 00 01` is the right command.
- [ ] **P6.3 Timeline alignment.** Cross-check a few all-day timestamps against
      Zepp Life's stress graph. Misalignment means the `0xFF` gap handling or
      the stream start time is wrong.
- [ ] **P6.4 Manual measurement.** Trigger a spot stress reading on the band and
      confirm it arrives as a `manual: true` record with a sane timestamp.
- [ ] **P6.5 RR-interval probe (settles the HRV question).** With verbose
      logging on, watch for `HR: RR INTERVALS PRESENT`. Exercise BOTH continuous
      (`15 01 01` + `16` keep-alive) and one-shot (`15 02 01`) modes. Expect
      none — record the flags byte observed in each mode either way.
- [ ] **P6.6 HRV fetch 0x49 probe.** Send `0x49` via `fetchRawData` with `0x13`
      as a positive control. Expect length 0 (as `0x48` did). Record the result.

---

## P7 — UI/UX (docs/ui-ux-review.md)

- [x] **P7.1 Dark mode on a device.** Done 2026-08-12, all five tabs at both
      scroll extremes plus Settings, Notifications and Stress. It was worth
      doing: the pass found a solid-white card and near-invisible headings, both
      from one cause (findings-22 §1), plus unreadable "on" switches. Charts and
      the card/scaffold separation held up.
- [x] **P7.2 System theme switch is live.** Done 2026-08-12 — and this was the
      bug. The palette repointed, but `const` widgets never rebuilt, so they
      kept the old colours. Fixed via `_PaletteGate`; pinned by
      `test/palette_swap_test.dart`. Re-check by hand after any change to how
      `AppColors.setPalette` is called.
- [ ] **P7.3 Largest accessibility font size.** Check for clipping, especially
      the hero numbers on Today/Heart/Sleep.
- [ ] **P7.4 Reduced motion.** Enable the OS setting and confirm decorative
      animation (the pulsing HR ring) stops.
- [ ] **P7.5 Screen reader.** TalkBack pass — expected to reveal the missing
      semantic labels listed as "Still open #1".

---

## P8 — Step-count source (findings-22, "Still open")

- [x] **P8.1 Reconcile the two step counts.** **RESOLVED 2026-08-13** — not a
      display bug and no reconciliation needed. History sync had stopped
      entirely: `_fetchActivityData` leaked a notify subscription per call, so
      after the second sync every control frame was handled twice, `0x02` was
      written twice, and the band answered `10 02 04` (error) instead of
      streaming. On top of that a single fetch stops at the first gap in the
      band's ring buffer, so even a working transfer could never climb past a
      hole. The summed-sample count was simply frozen while the realtime
      counter kept climbing. With the fetcher reused per connection and the
      fetch repeating until the band runs dry, the two now agree to within the
      last few minutes (4 211 vs 4 265). Original note kept below for context.

- [ ] ~~**P8.1 Reconcile the two step counts.**~~ On 2026-08-11 23:36 the band's own
      `0x0007` characteristic read **5,269 steps** while the UI showed **3,959**
      for the same moment. Today/Activity both derive their figure by summing
      minute-level activity samples; the realtime characteristic is the band's
      own running counter. Decide which is authoritative, then make one of them
      the single source. Likely explanation is that the summed samples miss
      whatever the fetch has not yet delivered — compare the two immediately
      before and immediately after a manual `syncNow()`.

---

## P9 — Stress: is the band answering, or are we reading our own buffer? (findings-23)

Everything here gates `BLEManager.kStressFetchVerified`, currently **false**.
Until P9.1 passes, the Stress screen shows a labelled heart-rate estimate and
stores nothing from the band.

- [ ] **P9.1 Does `0x13` return stress or activity?** *(gates all stress ingest)*
      On a **fresh connection**, issue `0x13` **alone**, with no preceding `0x01`,
      `since = now - 2 h`. Hex-dump the whole `10 01 01 <len32> <echoed start>`
      frame and the first 64 stream bytes. Then issue `0x01`, `0x13`, `0x12`
      back-to-back with an identical `since` and compare each declared `len32`.
      - `len(0x13) == len(0x01) == 8 × minutes`, first 8 bytes activity-shaped
        ⇒ the band serves activity for `0x13`; native stress does not exist on
        this firmware and the feature should be removed, not fixed.
      - `len(0x13) ≈ minutes` and `len(0x12) ≡ 0 (mod 5)` ⇒ the fault was
        entirely client-side (a buffer leak) and the parsers are correct.
      - Variants: repeat with stress monitoring **off** (`FE 06 00 00`) to tell
        an unconditional echo from a no-data fallback; issue a bogus type
        (`0x7F`) to see whether unknown types generically fall back to activity.
- [ ] **P9.2 Is the `0x12` layout real at all?** Take a spot stress reading on
      the band's own Stress widget, note the wall-clock minute, then fetch
      `0x12` with `since` 15 min earlier. A firmware implementing it must return
      a small buffer, `length ≡ 0 (mod 5)`, whose first `uint32 LE` decodes to
      that minute. Cross-check the all-day curve against Zepp Life for the same
      window.
- [ ] **P9.3 Does the band echo a start timestamp, and does it ever differ?**
      Log the full `10 01 01` frame and decode bytes[7..14] with GB's
      `rawBytesToCalendar` layout; compare against the requested `since`,
      including for a request older than the band's ring buffer.
      **Do not** switch the parse origin on the strength of theory — all 985
      overlapping activity round-pairs in the capture align at lag 0, so this is
      protocol-fidelity hardening, not a fix.
- [ ] **P9.4 Does the bare cleanup ACK destroy retained data?**
      `activity_fetcher.dart` sends a bare `0x03` inside `init()`, i.e. on every
      10-minute sync with no transfer in flight, while `protocol-mb6.md` §5
      documents `0x03` only as the post-transfer "delivered, you may drop it"
      ack. (1) Start a fetch and kill it mid-stream so no ack is sent.
      (2) Reconnect and send **only** `03`, wait 2 s. (3) Request the same range
      and read `10 01 01 <len32>`. `len32 == 0` ⇒ it destroys retained data and
      must go; unchanged ⇒ inert, keep it. **Leave it in place until this runs**
      — removing it unprobed risks reintroducing the stuck state it was added
      for.

## P10 — Sleep (findings-23)

- [ ] **P10.1 Are `0xFB` and non-`0xF` kind 9/11 ever really sleep?**
      Keep a written diary (lights-out, final awakening) for 3 nights and check
      every such minute against it. Prediction: they cluster at session
      transitions and post-wake re-donning, never inside diary-confirmed sleep.
      Whole-capture `0xFB`: n=33, median HR **85** — the highest of any
      `0xF`-flagged kind, against 65 for `0xF0`. The non-`0xF` cases are already
      excluded; `0xFB` is deliberately left in, because excluding it is unproven
      and it costs one minute on the night that prompted this.
- [ ] **P10.2 Re-derive the deep-sleep calibration on deduplicated data.**
      *(No longer a prediction — now observed.)* The table in
      `sleep_analyzer.dart` was fitted on captures carrying 56% duplicate
      samples, and its windows are indexed by position rather than by time, so
      duplicated minutes silently narrowed them.
      With de-duplication complete (2026-08-13, every day now exactly 1440
      samples), the median deep share across 20 nights sits at **10.2%** against
      a healthy-adult range of 13-23%, and one night reports 0% deep. Before
      dedup it read 13.7%.
      This is a *calibration* problem, not a staging bug — `_refineWithHeartRate`
      is doing what it was tuned to do, on windows that are now the size they
      were always supposed to be. Re-fit `_deepBaselineHalfWindow`,
      `deepDipBpm` and `_minDeepRunMinutes` against the deduplicated capture
      before trusting the deep figure. **Do not** tune it to hit 13-23% — that
      would be fitting to a prior. Tune the window arithmetic to what the
      original derivation intended, then report whatever it gives.

## P11 — Free upside, no risk

- [ ] **P11.1 What is activity byte[4]?** `ActivitySample` currently discards it.
      It reads 5 at rest (76.3%), then 7/13/15/21/23 — and in a byte-identity
      comparison it is 15/23/13/21 exactly on the walking minutes (steps 84, 83,
      36, 99) and 7 on a zero-step minute. Store it, walk a known distance, and
      check whether the running sum tracks calories or distance on the band's
      own screen and on `fee0/0x0007`. Display nothing until it does.
