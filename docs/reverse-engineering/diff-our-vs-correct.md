# Diff — Our code vs. Correct Mi Band 6 protocol (living document)

Legend: ✅ correct/fixed · ⚠️ partially wrong · ❌ wrong/missing · 🔵 confirm later

| # | Concern | Our code (before) | Correct (source) | Status |
|---|---|---|---|---|
| 1 | Auth handshake | legacy AES-ECB on `fee1/FEC1` — `ble_manager.dart` | legacy AES-ECB (`InitOperation`) — **GB**+**NOTIFY** | ✅ kept unchanged |
| 2 | Session key | none | none needed on legacy path | ✅ |
| 3 | Realtime HR — channel | stubbed; old attempt: `0x2A37` CCCD + cmds to `fee0/0x0008` | `0x2A37` notify + write to **`0x2A39`** — **GB**+**NOTIFY** | ✅ **fixed** (`_setupHeartRate`) |
| 4 | Realtime HR — start cmd | cmds to `fee0/0x0008` (inert) | `15 02 00` then `15 01 01` to `0x2A39` | ✅ **fixed** (`startRealtimeHeartRate`) |
| 5 | Realtime HR — parse | n/a | `bpm = data[1] & 0xFF` (7..249) | ✅ **fixed** (`_onHeartRateNotified`) |
| 6 | HR keep-alive | n/a | **`0x16` → `0x2A39` ≈14 s** — **NOTIFY** `x5/e.java` L() | ✅ **added** (12 s timer) |
| 7 | `GATT_WRITE_NOT_PERMITTED` on `0x2A37` | observed; blocked us | sequencing issue; enable notify post-auth + settle | ✅ addressed; 🔵 verify on device |
| 8 | Battery | `0x180F/0x2A19`, `data[0]` | canonical `fee0/0x0006`, level=`data[1]` — **GB**+**NOTIFY** | ✅ **fixed** (0x0006 + fallback) |
| 9 | Activity sample size | 4 bytes | **8 bytes** for MB6 — **GB**+**NOTIFY** | ✅ **fixed** (`_sampleSize=8`) |
| 10 | Activity fetch channel | `fee0/0x0004`+`0x0005` | same (legacy) | ✅ channel ok |
| 11 | Activity sample layout | `[cat,int,steps(2B)]`, HR=0 | `[cat,int,steps(1B),HR,_,sleep,deep,rem]` — **NOTIFY** | ✅ **fixed** (`_parseActivityData`) |
| 12 | HR history source | separate fetch type `0x0D` (= sleep!) | embedded at byte 3 of activity samples | ✅ **fixed** (`heartRatesFromSamples`) |
| 13 | SpO2 fetch type | `0x12` (= stress!) | **`0x25`** — **NOTIFY** | ✅ **fixed**; ⚠️ sample layout unverified |
| 14 | Metadata byte 7 | read as sample size | echoed start-timestamp | ✅ **fixed** (removed misread) |
| 15 | Chunked `0x0016/0x0017` | none | not used for HR/activity/battery on MB6 | ✅ (correctly absent) |
| 16 | User info char | `0x4f…` → `fee0/0x0008` | `fee0/0x0008` user settings | 🔵 confirm payload |
| 17 | Time sync | `0x2A2B` 11-byte blob | Current Time `0x2A2B` | ✅ likely |
| 18 | Notification payload byte[5] | `0x00` | **`0x01`** — GB `onNotification` | ✅ **fixed** (findings-17) |
| 19 | Notification icon byte[6] | hard-coded `0xFA`; `icon:` arg discarded | **Huami icon id**, generic = 11 — GB `HuamiIcon` | ✅ **fixed** (`huami_icon.dart`) |
| 20 | Notification text fields | `"" \0 body \0 title \0`; app name never sent | **`title \0 body \0 appName \0`** — GB | ✅ **fixed** |
| 21 | Notification padding | zero-padded to ≥18 B | **no padding** — GB | ✅ **fixed** |
| 22 | Notification chunking | always one `00 C0 00` frame, truncated at 230 B | `writeToChunkedOld`: `0x80`/`0x40`/`0xC0` by position, chunk = `min(512,max(23,mtu)-3)-3` | ✅ **fixed** (`buildChunks`) |
| 23 | Incoming call channel | `fee0/0x0020` chunked, 10-byte cmd | **`0x2A46` ANS, `[03 01]+caller`** — GB `AmazfitBipTextNotificationStrategy` | ✅ **fixed** |
| 24 | Call dismiss | `[03,0,0,0,0,0,0,0,0,3]` | **`[03 00]` → `0x2A46`** | ✅ **fixed** |
| 25 | MTU used for chunking | requested 247, never read back | use the **negotiated** value | ✅ **fixed** (`setMtu`) |
| 26 | Notification bridge lifetime | channel on MainActivity's engine — dies with the activity | channel on a **process-lifetime engine** | ✅ **fixed** (`BandApplication.kt`) |
| 27 | Listener rebind | none | `requestRebind()` on disconnect | ✅ **added** |
| 28 | MessagingStyle text | only `EXTRA_TITLE`/`EXTRA_TEXT`/`EXTRA_BIG_TEXT` → chat apps arrived blank and were dropped | also `EXTRA_MESSAGES`, `EXTRA_TEXT_LINES` | ✅ **fixed** |
| 29 | Sleep kind mapping | `112/121/122/126/128` (ZeppOS `HuamiExtendedSampleProvider`) | legacy `HuamiConst`: **9=light, 11=deep, 3/6=not worn**, `&0x0F`, carry-forward 0/10 | ⚠️ **hardware disagrees** — see protocol §7.2, probe P2.1; fix pending Phase 2 |
| 30 | Not-worn detection | assumed `intensity == 0xFF` | **kind 3 (nonwear) / 6 (charging)** — GB `HuamiConst:134-137` | ❌ still `sleep>0` heuristic; fix pending Phase 2 |
| 31 | Sleep session gap | 60 min merge, 25 min min span | GB: **5 min min session, 60 min max wake gap, any stepped minute breaks it**, 18:00→18:00 day | ❌ fix pending Phase 2 |
| 32 | Stages fetch `0x48` | not attempted | gated on `supportsSleepScore()` (ZeppOS only); **probed on our band → length 0** | ✅ documented, correctly absent |
| 33 | Activity HR byte | out-of-range HR rewritten to `0` | GB keeps the raw byte; validity is `>0 && >=10 && <=250` | 🔵 keep 0, but filter on read |
| 34 | Sample `unknown1` (offset 4) | dropped | GB persists it | 🔵 low value on MB6 |

Source tags: **GB**=Gadgetbridge, **NOTIFY**=com.mc.miband1.
