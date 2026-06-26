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

## Iteration log
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
- **03** (2026-06-24): hardware test-session instrumentation — gated runner
  (`hardware_test_session.dart`) running gates 0→6 halt-on-fail with one greppable
  `MB6TEST GATEn` banner each, capture-on-fail dumps (Gate 3 GATT code, Gate 6 raw
  hex), and a Gate-5 keep-alive auto-probe (12→8→15 s). Trigger in Settings →
  Developer. Adds `hardware-test-session.md` + `test-results-01.md` template.
  No protocol opcodes changed.
