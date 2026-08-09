# Reverse-Engineering Mi Band 6 — Index & Status

Goal: make heart rate (realtime + history), activity, and battery work on Mi Band 6
by extracting the real wire protocol from the **Notify** (`com.mc.miband1`) and
**Mi Fit** APKs, cross-checked against **Gadgetbridge**, then fixing our Dart code.

## Documents
| File | Purpose |
|---|---|
| `protocol-mb6.md` | **Authoritative spec** — UUIDs, opcodes, byte layouts, sources. |
| `diff-our-vs-correct.md` | Living "we do X / correct is Y" table. |
| `findings-01.md` | Setup, Gadgetbridge extraction, Notify package map, hypothesis test. |
| `findings-02.md` | Notify deep-dive (HR/fetch/battery/device-model) + implementation. |
| `findings-03.md` | Hardware test-session instrumentation (gated runner + auto-probe). |
| `findings-08.md` | **SpO2 parser fix** — type 0x25 is 1 version byte + N×65-byte records (ts uint32 LE + spo2 `&0x7F`); hand-decoded real bytes → 98/99 %. |
| `findings-09.md` | **Sleep-stage decode** — MB6 has no 0x48 session stream + never sets the REM byte; deep is the masked deepSleep byte (`&0x7F > 52`, data-driven). Deep 6 m → 1 h23 m (17 %); REM omitted as untracked. |
| `findings-10.md` | **Sleep-audio (mic snoring)** — privacy model + Android mic-FGS design; hardware verification (capture, screen-off survival, clean stop, no audio persisted/transmitted). Feature doc: `../sleep-audio.md`. |
| `findings-11.md` | **Sleep screen trust pass** — auditable score breakdown, gated personalization (post-fix nights), sleep-debt (gated), recovery omitted, AI "coming soon". Docs: `../sleep-score.md`, `../sleep-baseline.md`, `../deferred-sleep-metrics.md`. |
| `findings-12.md` | **Heart screen trust pass** — status/trend hero + resting prominence, real HR-vs-activity correlation, zone-banded chart, gated weekly summary (shared `Baseline`), Day/Week/Month. No "Heart Score" (trend/status instead); Stress "coming soon", Recovery omitted (no HRV). Docs: `../heart-score.md`. |
| `findings-13.md` | **Activity screen trust pass** — coach hero (status/pace), insights, sedentary stretch, active/brisk minutes (step-cadence; intensity rejected as noisy), Day/Week/Month, gated comparisons/streaks, decomposable Activity Score. **Fixes a ~4.3× step over-count** (band repeats each minute's count across sub-minute samples). Floors omitted (no altimeter). Docs: `../activity-score.md`. |
| `findings-14.md` | **Today screen trust pass** — composite Health Score that COMPOSES Sleep+Activity+Heart-status (breakdown shown, missing inputs named, Heart has no number), briefing, aggregated insights, salience-ordered cards that deep-link to detail tabs, gated trends, goal cluster, watch-status block. **No Recovery (no HRV), no Hydration (no sensor).** Docs: `../health-score.md`. |
| `findings-15.md` | **Performance** — why the app lagged (notify fan-out × wholesale `context.watch` × O(n) analyses in `build()` × O(n)-per-heartbeat store) and the selective-rebuild / memoisation fix. |
| `findings-16.md` | **Background connection** — ConnectionPhase state machine, 1/2/5/15/30/60 s backoff with jitter, adapter awareness, half-open-link liveness heartbeat, persisted connect intent. |
| `findings-17.md` | **Notifications** — the warm-FlutterEngine fix (channel died with the activity) + the five payload defects vs Gadgetbridge, incl. calls on ANS `0x2A46`. |
| `findings-18.md` | **Sleep accuracy** — the stage table was ZeppOS's, not MB6's; rebuilt session detection (5 min/60 min/steps-break/18:00 day), not-worn by kind, HR-dip deep staging. |
| `findings-19.md` | **Band settings** — every config command with its target characteristic; re-applied on every reconnect. |
| `findings-20.md` | **Stress** — MB6 measures stress natively (0x13/0x12); full `0x2A37` flags decode proves this firmware sends **no RR intervals**, so no HRV. |
| `findings-21.md` | **The sleep encoding, settled on 60 404 live samples** — the kind byte is two independent nibbles (high `0xF` = asleep, low = HuamiConst kind incl. NONWEAR). Exposed and fixed three defects: a sleep gate over-reporting ~30 %, sessions merging into 31-hour "nights", and a `deepSleep` byte with no physiological signal. |
| `pending-hardware-verification.md` | **Everything not yet confirmed on the band** — read this before trusting any claim from the 2026-08-09 overhaul. |
| `verification-checklist.md` | Per-claim → log-line checklist to confirm fixes on the real band. |
| `hardware-test-session.md` | **Runnable** gated session guide (gates 0→6) for the physical band. |
| `test-results-NN.md` | Per-run results template (fill after each hardware run; never overwrite). |

## ✅ SOLVED (findings-07) — HR works on the real band
- Implemented the Huami **2021 sign-key (ECDH) auth** (`ecdh_b163.dart` +
  `huami2021_chunked.dart` + `huami2021_auth.dart`, all unit-tested). On hardware:
  `2021 SIGN-KEY AUTHENTICATION SUCCESS` → **all 7 gates pass**
  (`MB6TEST SUMMARY p=7 … [0:P 1:P 2:P 3:P 4:P 5:P 6:P]`): real BPM=68, HR sustained
  90 s at the 12 s keep-alive, activity parsed. Full auth unlocks the standard
  `0x2A37/0x2A39` HR service + fee0 fetch (no data needs the chunked channel).
- Normal-use path verified: `HR notify: 00 49 -> 73 bpm`. See `test-results-01.md`.

## Root-cause history (findings-06)
- **This Mi Band 6 firmware requires the Huami SIGN-KEY (ECDH / 2021-class) auth.**
  On-device proof: the canonical legacy AES-ECB handshake now runs perfectly
  through all 3 steps but the band's final status is `0x07` = **"sign key failed"**
  (Notify `R.string.pairing_signkey_failed`; `0x08` would be auth-key-failed, so the
  auth key is fine). This **overturns** findings-01..05's assumption that MB6 uses
  pure legacy auth.
- Consequences confirmed on hardware: the standard `0x180D` HR service
  (`0x2A37`/`0x2A39`) returns `GATT_WRITE_NOT_PERMITTED (code=3)` and the activity
  fetch gets no response — both gated behind full (sign-key) auth. Battery/steps
  work because they read with partial auth.
- Earlier eliminations (all captured): post-auth sequencing, the `06 1f 00 01`
  third-party flag, and Android bonding (`createBond` succeeds, HR still locked).
- **Real unlock = implement the sign-key/ECDH auth** (port `ECDH_B163` +
  `InitOperation2021` + chunked `0x0016/0x0017` transport from Gadgetbridge).
  Surfaced to the user as a scope decision.

## Status checklist
| Item | Status |
|---|---|
| Toolchain (jadx/apktool) + decompile Notify | ✅ done |
| Gadgetbridge clean-room reference | ✅ extracted |
| Locate Notify protocol packages | ✅ mapped (`x5/`, `com/mc/miband1/bluetooth/`) |
| Test chunked hypothesis | ✅ refuted for MB6 (GB **and** Notify) |
| Realtime HR spec | ✅ confirmed (GB + Notify) incl. keep-alive ping |
| Activity/HR-history/SpO2 fetch spec | ✅ confirmed (8-byte layout, correct types) |
| Battery spec | ✅ confirmed (`fee0/0x0006`) |
| Implement HR (realtime + one-shot) in Dart | ✅ done (`ble_manager.dart`) |
| Implement battery + activity-fetch fixes | ✅ done |
| Hardware test-session runner (gates 0→6, halt-on-fail) | ✅ done (`hardware_test_session.dart`) |
| Gate-5 keep-alive auto-probe (12/8/15 s) | ✅ done |
| Verify on device (run gated session) | ⏳ pending real-device run → fill `test-results-01.md` |
| UI performance (selective rebuilds, memoised analyses) | ✅ done, ⏳ device profile pending (P1.1) |
| Connection supervisor (backoff/adapter/liveness) | ✅ done, ⏳ unverified (P4) |
| Notifications end-to-end (warm engine + correct payload) | ✅ done, ⏳ unverified (P5) |
| Sleep analyzer rebuild | ✅ done, ⏳ accuracy unverified (P2.3) |
| Band settings (all config commands) | ✅ done, ⏳ unverified (P3) |
| Native stress fetch (0x13/0x12) | ✅ done, ⏳ unverified (P6) |
| RR intervals / HRV | ❌ **not available on this firmware** (34/34 packets, flags 0x00) |
| Light + dark theme, contrast-tested | ✅ done, ⏳ never seen on a device (P7.1) |
| Hardware gates 7-10 (sleep/notif/settings/stress) | ✅ added, ⏳ never run |

## Iteration log
- **21** (2026-08-10, band worn overnight): **Audited the shipping pipeline
  against 60 404 real samples over 53 days.** Settled the §7.2 contradiction —
  the category byte is *two* nibbles, and Gadgetbridge was right about the low
  one all along. Found the sleep/wake gate (`sleep byte > 0`) marking 10 831
  extra samples asleep, mostly 20:00-00:00 evening stillness, inflating sleep
  ~30 %; found `0xF3` (0.04 % heart-rate coverage — the band recording nothing)
  being counted as sleep, which produced 14-hour "nights"; and found the
  `deepSleep` byte carries no stage information at all (mean HR flat across
  every bucket). Replaced the wake scorer with **Chinoy 2020**, the only
  algorithm validated against PSG on a *Huami* per-minute scalar (90.3 %
  accuracy, published threshold), corrected Cole-Kripke's coefficients to the
  real published ones, and rebuilt deep sleep on a circadian-**detrended**
  heart-rate dip. Stopped the HR aligner interpolating across ±5 min, which
  could manufacture deep sleep out of a sensor dropout. Added the **Sleep
  Regularity Index** (Phillips 2017; real value 70.1) and fixed the stress
  baseline to compare like-with-like across the circadian cycle. Deep share went
  from a median 5.7 % (0-41 %) to 13.4 %, impossible nights 3 → 0.
  **Hardware-verified:** sign-key auth intact, supervisor backoff live, every
  config command accepted, and a real bug caught — the HR-streaming intent was
  not persisted, so a restart resumed the 1 Hz drain that would have flattened a
  28 %-battery band before morning.
- **15-20** (2026-08-09): **Full overhaul.** Performance (findings-15): root-caused
  the lag as a chain — every BLE notify called `notifyListeners()`, every tab did a
  top-level `context.watch<BLEManager>()`, every rebuild re-ran three O(n) analyses,
  and `addHeartRateReadings` rebuilt an O(n) dedup set *per heartbeat*. Fixed with
  per-value notifiers, revision-keyed memoisation, incremental store indexes,
  isolate JSON encoding, a bounded/coalesced logger, and one service discovery per
  connection instead of nine. Connection (16): explicit `ConnectionPhase`, jittered
  exponential backoff, adapter awareness, liveness heartbeat, persisted intent, and
  the service no longer stops mid-reconnect. Notifications (17): the channel lived
  on MainActivity's FlutterEngine and died with it — moved to a process-lifetime
  engine; payload corrected in five ways and calls moved to ANS `0x2A46`. Sleep (18):
  our stage table was `HuamiExtendedSampleProvider`'s (ZeppOS) and never matched;
  rebuilt on the legacy kinds with GB's session rules, not-worn by kind (not
  `intensity==0xFF`), and HR-dip deep staging replacing an eyeballed byte threshold.
  Settings (19): all band config commands with correct target characteristics,
  re-applied after every auth. Stress (20): MB6 **does** measure stress natively —
  implemented 0x13/0x12 — and a full `0x2A37` flags decode confirmed this firmware
  sends **no RR intervals**, so HRV/recovery stay omitted. UI: light+dark palettes
  with contrast enforced by test (which found and fixed 8 real light-theme
  failures). **Hardware-verified: nothing — no device was attached; see
  `pending-hardware-verification.md`.**
- **01** (2026-06-24): decompile setup, GB extraction, Notify map, hypothesis refuted.
- **02** (2026-06-24): Notify deep-dive confirmed legacy HR/fetch/battery + keep-alive;
  enum contradiction adjudicated (MB6 = `MILI_PANGU`); implemented HR realtime +
  one-shot, battery `fee0/0x0006`, 8-byte activity samples + HR-from-activity, SpO2
  type fix. Code in `ble_manager.dart` + `activity_fetcher.dart`.
- **04-07** (2026-06-24/25): autonomous adb hardware loop. Built a headless
  intent trigger; baseline showed Gate 3 `WRITE_NOT_PERMITTED (code=3)`; refuted
  the third-party-flag and bonding hypotheses; switched auth to the canonical
  `0x0009` char and found status `0x07` = sign-key-failed → the band needs the
  Huami 2021 **sign-key/ECDH** auth (findings-06). Ported `ECDH_B163` +
  Huami2021 chunked transport (unit-tested) and implemented the sign-key handshake
  (findings-07) → **all 7 gates pass, HR works** on the real band.
- **08** (2026-06-26): **SpO2 parser fix.** The fetch type (0x25) was right but
  the record layout was never decoded — the parser read one byte every 2 bytes,
  so reading 1 (the version byte `0x02`) gave "2 %" then stride-2 junk
  (2/25/45/69 %). Re-derived the layout from Gadgetbridge `FetchSpo2NormalOperation`
  (1 version byte + N×65-byte records: uint32-LE seconds + spo2 `&0x7F`), captured
  the real 131-byte buffer over adb and hand-decoded both records → **98 % / 99 %**.
  Fixed `_parseSpo2Data`; restored the SpO2 metric in the UI. No transport changes.
- **14** (2026-06-28): **Today screen trust pass.** Rebuilt the homepage as a
  health briefing that COMPOSES the three engines via a pure `DailySummary`:
  composite Health Score (Sleep 0.40 + Activity 0.35 + Heart-status 0.25,
  re-normalised over available components, breakdown always shown, Heart has no
  number), data-driven briefing, aggregated attention-first insights, summary
  cards ordered by a discrete salience rule that deep-link into the detail tabs,
  gated trend chips, a Steps+Sleep goal cluster (unclamped %) and an informative
  band-status block. Refused the homepage traps: **no Recovery score (no HRV),
  no Hydration (no sensor)**. Verified the step over-count fix propagated (Today
  shows corrected totals = band counter). UI composition only. Docs:
  `findings-14.md`, `../health-score.md`.
- **13** (2026-06-28): **Activity screen trust pass.** Pure `ActivityAnalysis`
  engine (status/pace, sedentary stretch, active/brisk minutes, peak hour, gated
  comparisons/streaks, decomposable Activity Score). On-device data revealed the
  band emits each minute's step count across ~5 sub-minute samples, so the store's
  `Σ steps` over-counted ~4.3× (4,538-step day → 19,592); added `stepsPerMinute()`
  and routed the store's aggregation through it (now matches the band counter
  exactly). Intensity found unreliable for movement (high even at rest) → step
  cadence used instead. Floors omitted (no altimeter); percentages never clamped.
  UI only + that aggregation fix; verified on Pixel. Docs: `findings-13.md`,
  `../activity-score.md`.
- **12** (2026-06-27): **Heart screen trust pass.** Reframed the bare BPM
  dashboard into a heart-health view: `HeartAnalysis` engine (status, resting
  prominence, trend, real HR-vs-activity correlation, gated weekly stats),
  shared `Baseline` gate across Sleep+Heart, zone-banded chart with min/avg/max
  markers, Day/Week/Month, recommendations. Decided against a "Heart Score"
  (trend/status framing instead — no HRV to make it auditable); Stress
  "coming soon", Recovery omitted. UI only; verified on Pixel. Docs:
  `findings-12.md`, `../heart-score.md`.
- **03** (2026-06-24): hardware test-session instrumentation — gated runner
  (`hardware_test_session.dart`) running gates 0→6 halt-on-fail with one greppable
  `MB6TEST GATEn` banner each, capture-on-fail dumps (Gate 3 GATT code, Gate 6 raw
  hex), and a Gate-5 keep-alive auto-probe (12→8→15 s). Trigger in Settings →
  Developer. Adds `hardware-test-session.md` + `test-results-01.md` template.
  No protocol opcodes changed.
