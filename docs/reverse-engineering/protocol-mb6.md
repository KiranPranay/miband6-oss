# Mi Band 6 — Reconstructed BLE Protocol (authoritative spec)

> Every assertion cites its source: **GB** = Gadgetbridge class:line,
> **NOTIFY** = decompiled `com.mc.miband1` class, **MIFIT** = `com.xiaomi.hm.health`.
> Items not yet cross-confirmed are tagged **UNVERIFIED**.

## 0. TL;DR — which protocol family is Mi Band 6?

**Mi Band 6 is a LEGACY Huami device**, the same protocol family as Mi Band 4/5.
It is **not** a "Huami 2021 / ZeppOS" chunked device. Decision evidence:
`HuamiSupport.force2021Protocol()` defaults `false` and is not overridden by
`MiBand6Support`/`MiBand5Support` (**GB** `HuamiSupport.java:3961`,
`MiBand6Support.java`). That single flag is what would have switched auth to ECDH
and data to the `0x0016/0x0017` chunked channel. It stays off for MB6.

Consequences:
- **Auth** = legacy AES-ECB challenge on `fee1/FEC1` (our app already does this and
  it works).
- **Realtime HR** = standard GATT Heart-Rate service `0x180D` (`0x2A39` control,
  `0x2A37` measurement).
- **Activity/HR-history/SpO2 fetch** = legacy `fee0/0x0004`(control)+`0x0005`(data).
- **Battery** = Huami `fee0/0x0006` (and/or standard `0x180F/0x2A19`).
- The chunked `0x0016/0x0017` channel is **not used for HR/activity/battery**. (Per
  Notify, newer MB6 firmware ≥ `1.0.4.1` that advertises an encryption capability
  *can* route encrypted *config/handshake commands* over it — but Gadgetbridge drives
  MB6 entirely in plaintext, and our band's plaintext auth/alerts already work, so we
  do not need it. Full spec in Appendix A as a future contingency.)

> **Device-enum note (findings-02 §6):** in Notify, Mi Band 6 = enum `MILI_PANGU`
> (`G1`, id 211) / `MILI_PANGU_L` (`H1`, id 212), displayed "Mi Band 6 (NFC)".
> `MILI_L66` (id 262) is **Mi Band 7**, not 6.

## 1. Services & characteristics

### 1.1 Huami private service `fee0` — `0000fee0-0000-1000-8000-00805f9b34fb`
Characteristic UUIDs are `0000NNNN-0000-3512-2118-0009af100700`
(**GB** `HuamiService.java:43-58`):

| `NNNN` | Name | Props | Use |
|---|---|---|---|
| `0003` | configuration | write/notify | config commands (`0x06 …`), fitness goal, time format |
| `0004` | activity **control** | write/notify | fetch control opcodes |
| `0005` | activity **data** | notify | fetch data stream |
| `0006` | battery info | read/notify | battery level + charge state |
| `0007` | realtime steps | read/notify | live steps/distance/calories |
| `0008` | user settings | write | user profile (age/height/weight/sex) |
| `0010` | device events | notify | button/event push |
| `0016` | chunked-2021 **write** | write | *(MB6: unused)* |
| `0017` | chunked-2021 **read** | notify | *(MB6: unused)* |
| `0020` | chunked (old) / alert | write | custom notifications (our `AlertManager`) |

### 1.2 Auth service `fee1` — char `fec1` (`…FEDD…`? no: `fee1`/`fec1` per our app)
Used only for the legacy handshake.

### 1.3 Standard Heart-Rate service `0x180D` — `0000180d-0000-1000-8000-00805f9b34fb`
| UUID | Name | Props |
|---|---|---|
| `00002a37-…` | HR Measurement | notify |
| `00002a39-…` | HR Control Point | write |

(**GB** `GattCharacteristic.java:80,82`.)

### 1.4 Standard Battery service `0x180F` — char `0x2A19` (read/notify)

## 2. Authentication (legacy, AES-ECB) — **WORKING in our app, do not change**

Source: **GB** `operations/init/InitOperation.java`; matches our
`ble_manager.dart` `_startAuthHandshake`/`_handleAuthResponse`.

```
→ FEC1: 01 <authFlags> <16-byte auth key>
← FEC1: 10 01 01                       (key accepted)   [or 10 01 04 = rejected]
→ FEC1: 02 <authFlags>                 (request challenge)
← FEC1: 10 02 01 <R0..R15>             (16 random bytes)
   enc = AES_ECB_NoPadding(authKey, R0..R15)
→ FEC1: 03 <cryptFlags> <enc0..enc15>
← FEC1: 10 03 01                       (AUTH SUCCESS)    [or 10 03 04 = key mismatch]
```
No session key, no post-auth encryption.

## 3. Realtime heart rate  ✅ (the fix)

Source: **GB** `HuamiSupport.java:1509-1554, 594-597, 2181-2193`,
`MiBandService.java:186-187`. **NOTIFY CONFIRMED** (`x5/e.java` z0/y/q/L,
`BLEManager.java` m1/l1; findings-02 §2).

**Characteristics:** control = `0x2A39`, measurement/notify = `0x2A37` (service `0x180D`).

**Command bytes → `0x2A39`:**
| Action | Bytes |
|---|---|
| stop continuous | `15 01 00` |
| **start continuous** | `15 01 01` |
| stop manual | `15 02 00` |
| **start manual (one-shot)** | `15 02 01` |

**Start continuous realtime HR:**
1. enable notifications on `0x2A37`
2. write `15 02 00` (stop manual) to `0x2A39`
3. write `15 01 01` (start continuous) to `0x2A39`

**One-shot HR test:** notify `0x2A37` → `15 01 00` → `15 02 00` → `15 02 01`.

**Stop:** write `15 01 00` to `0x2A39` (+ disable `0x2A37` notify).

**Parse `0x2A37` notification:** if `len==2 && b[0]==0` ⇒ `bpm = b[1] & 0xff`.
(Some firmwares also send `len>2` with a flags byte per BT HR spec — handle both:
if `b[0] & 0x01` the value is uint16 at `b[1..2]`, else uint8 at `b[1]`.) **UNVERIFIED** for MB6 — confirm in 02.

**Keep-alive:** ✅ **CONFIRMED REQUIRED.** Notify writes a single byte `16` to
`0x2A39` ≈ every 14 s while continuous HR is active (`x5/e.java` `L()` L3674,
driven by `BLEManager.l1()` L2877 with a 14000 ms threshold). Without it the band
stops streaming. Our impl pings every 12 s (margin). (GB's MB6 base omits it; Notify
— the app that works with the user's band — sends it, so we follow Notify.)

## 4. Battery

Source: **GB** `HuamiService.java:46`, `HuamiSupport.java:546,601,2511`,
`HuamiBatteryInfo.java`. **NOTIFY CONFIRMED** (`x5/e.java` B1, `r6/b.java` e();
findings-02 §4).

- Read + notify `fee0/0x0006`.
- Payload layout: `byte[0]` = flags, `byte[1]` = level %, `byte[2]` = charge state
  (0 normal, 1 charging; present when flags bit0 set).
- `0x180F/0x2A19` returns level in `byte[0]`; used only as a fallback (it is the
  ZeppOS path, not MB6's canonical source).

## 5. Activity / HR-history / SpO2 fetch (legacy char-based)

Source: **GB** `operations/fetch/AbstractFetchOperation.java`,
`FetchActivityOperation.java`; chars `fee0/0x0004`+`0x0005`
(**GB** `HuamiService.java:44-45`). MB6 sample size = **8 bytes**
(**GB** `MiBand6Support.java:75`). **NOTIFY CONFIRMED** (`x5/e.java` N2/onNotify,
`helper/b.java` r()/s(); findings-02 §3).

**Data-type byte (2nd byte of start cmd):** `01`=activity (steps+HR+intensity+sleep,
8-byte stream), `05`=HR/manual-HR history, `0D`=sleep, `12`=stress, `13`=stress
all-day, **`25`=SpO2**, `26`=SpO2 variant, `07`=raw log. ⚠️ `0x12` is **stress**
(not SpO2) and `0x0D` is **sleep** (not HR) — both were wrong in the old code.

**MB6 8-byte sample layout:** `[0]`category/kind, `[1]`intensity, `[2]`steps
(single byte 0-255), `[3]`**heart rate** (0/255 ⇒ no reading), `[4]`unknown1,
`[5]`sleep, `[6]`deepSleep, `[7]`remSleep; sample N = start + N minutes. HR history
is read from byte 3 here — there is no separate per-minute HR fetch.

**Metadata response** (`← 0x0004`): `10 01 01 | count(uint32 LE @bytes3-6, excludes
per-packet counter bytes) | start-timestamp(@bytes7-14)`. ⚠️ byte 7 is the echoed
start date, **not** a sample size.

High-level handshake (our `activity_fetcher.dart` already follows this shape):
```
→ 0004: 01 <type> <year_lo year_hi month day hour min> 00 <tzQuarters>   (start)
← 0004: 10 01 01 <len32 LE> <sampleSize?> ...                            (accepted + count)
→ 0004: 02                                                              (begin transfer)
← 0005: <counter> <payload…> (repeated)
← 0004: 10 02 01                                                        (transfer done)
→ 0004: 03                                                              (ack/stop)
```
Per-packet data framing (`← 0005`): `byte[0]`=sequence counter (drop), `byte[1..]`=
payload, accumulated until `count` bytes received.

## 5b. Realtime steps/distance/calories — `fee0/0x0007` (read + notify)

Source: on-device capture (findings-07 follow-up). **READ** the char for the
current daily total (notify only fires while the count changes); also subscribe
to notify for live updates. 13-byte packet, e.g. `0c 13 00 00 00 0d 00 00 00 01
00 00 00`:
| bytes | field |
|---|---|
| `[0]` | category/flag |
| `[1..2]` | steps (uint16 LE) — running daily total |
| `[3..4]` | unknown / 0 |
| `[5..8]` | distance in **metres** (uint32 LE) |
| `[9..12]` | calories (uint32 LE) |

⇒ that example = 19 steps, 13 m, 1 kcal. (GB only reads steps from this char;
distance/calories at `[5..8]`/`[9..12]` confirmed from the real packet.)

## 6. Time, display, user info, fitness goal (config char `fee0/0x0003`)
- Time sync: GB writes the 11-byte time blob to the **Current Time** char
  (`0x2A2B`) — our `_syncTime` matches. **(confirm char in 02.)**
- Config commands begin `0x06` (`ENDPOINT_DISPLAY`) and go to `fee0/0x0003`.
- `COMMAND_ENABLE_HR_CONNECTION = 06 1f 00 01` ("expose HR to 3rd-party apps")
  goes to **`0x0003`** (**GB** `HuamiService.java:155`) — *not* `0x0008` as our
  old HR attempt did. Optional for realtime HR.

---

## 7. Sleep classification from activity samples

**Sources:** GB `HuamiConst.java:36-46,124-144`, `MiBand2SampleProvider.java:50-95`,
`MiBand6Coordinator.java:42`, `HuamiCoordinator.java:177-179`;
hardware capture in `findings-09.md`.

Mi Band 6 rides the **legacy** Huami sample path: `MiBand6Coordinator extends
HuamiCoordinator` and does not override `getSampleProvider()`, so it uses
`MiBand2SampleProvider` → `HuamiConst.toActivityKind`. **`HuamiExtendedSampleProvider`
(raw kinds 120-123) is instantiated only by `ZeppOsCoordinator` and never applies
to MB6.**

### 7.1 Legacy raw-kind table (byte 0 of each 8-byte sample)

| raw | constant | maps to |
|---|---|---|
| -1 | TYPE_UNSET | not measured |
| 0 | TYPE_NO_CHANGE | *carry forward previous valid kind* |
| 1 | TYPE_ACTIVITY | activity |
| 2 | TYPE_RUNNING | activity |
| 3 | TYPE_NONWEAR | **not worn** |
| 4 | TYPE_RIDE_BIKE | cycling |
| 6 | TYPE_CHARGING | **not worn** |
| 9 | TYPE_LIGHT_SLEEP | **light sleep** |
| 10 | TYPE_IGNORE | *carry forward previous valid kind* |
| 11 | TYPE_DEEP_SLEEP | **deep sleep** |
| 12 | TYPE_WAKE_UP | activity (**not** a sleep kind) |

Rules GB applies (`MiBand2SampleProvider.postprocess`):
- mask `rawKind & 0x0F` (unless the value is `-1`); the high nibble carries
  non-kind flags. GB's own exclusion list `{0, 10, -1, 16, 80, 96, 112}` is
  commented "all I ever had that are 0 when doing &=0xf".
- `TYPE_NO_CHANGE`/`TYPE_IGNORE` samples inherit the last valid kind.

**On the legacy path there is no REM and no AWAKE kind** — `toActivityKind` has
no case for either, and `MiBand6Coordinator` inherits
`supportsRemSleep() == false` / `supportsAwakeSleep() == false`.

**Not-worn is a kind value (3 or 6), NOT `intensity == 0xFF` and NOT `HR == 255`.**
Invalid HR is filtered separately: `HeartRateUtils.isValidHeartRateValue` accepts
`> 0 && >= 10 && <= 250`.

### 7.2 ⚠️ Hardware disagrees with the table — unresolved

Our own captures (`findings-09.md` §3, real `activity_data.json`) show byte 0 on
this MB6 (MILI_PANGU, FW V1.0.7.40) is **`0xF3`(243) / `0xF0`(240) overnight and
`0x50`(80) during the day** — never 9 or 11. Masked with `& 0x0F` those become
3 / 0 / 0, i.e. "not worn" and "no change", which cannot be right for a night of
sleep.

Two possibilities, not yet distinguished: the high nibble is a sleep flag whose
meaning GB does not model for this firmware, or this firmware simply reports
different kinds. **Hardware wins over the reference**, so the analyzer treats the
`sleep` byte (offset 5) as the primary asleep gate — which findings-09 verified
maps 1:1 to the 0xF0/0xF3 overnight values — and additionally honours GB's 9/11
kinds where present. A probe that dumps the observed kind-byte histogram is
queued as **P2.1** in `pending-hardware-verification.md`.

### 7.3 Session stitching (GB `SleepAnalysis.calculateSleepSessions`)

- minimum session length **5 min**; maximum wake gap inside a session **1 hour**;
- **any minute with steps breaks the session**;
- the "sleep day" window runs **18:00 → 18:00**, which is how a bedtime before
  midnight is attached to the following day.

### 7.4 The 0x48 sleep-session stream does not exist on MB6

`FetchSleepSessionOperation` (594-byte records, full stage timeline + the band's
own score) is gated on `coordinator.supportsSleepScore()`, which only
`ZeppOsCoordinator` returns true for. Independently, we **probed the band
directly**: fetch type `0x48` was accepted and returned
`expected data length = 0` (`findings-09.md` §1). Same for
`SLEEP_RESPIRATORY_RATE` (0x38). So stages must come from the per-minute stream.

---

## 8. Notifications

**Sources:** GB `HuamiSupport.onNotification`, `writeToChunkedOld` (:3766-3792),
`HuamiIcon.java:26-128`, `AmazfitBipTextNotificationStrategy`;
Notify `y5/q.java`, `x5/i0.java`. Cross-checked; see `findings-17.md`.

### 8.1 App notification — `fee0/0x0020`, old-chunked, type 0

```
[0xFA][0x00 0x00 0x00 0x00][0x01][iconId]
  utf8(title)   0x00
  utf8(body)    0x00
  utf8(appName) 0x00
```

- 7 header bytes, then exactly **three** NUL-terminated UTF-8 fields.
- No padding and no terminator beyond the final `0x00`.
- Total command capped at `notificationMaxLength() = 230`; text budget = 223.
- `[1..4]` is GB's `notificationHasExtraHeader()` block (true from MiBand4Support
  onward). Notify shows the same block as `flag + 4-byte LE notification id`;
  either way the **icon always lands at index 6** and GB writes `0x01` at index 5.

### 8.2 Old-chunked framing (`writeToChunkedOld`)

```
MAX_CHUNKLENGTH = min(512, max(23, mtu) - 3) - 3     // 17 @ MTU 23, 241 @ MTU 247
frame = [0x00][flags | type][count][payload slice]
```

| flags | meaning |
|---|---|
| `0x80` | last chunk |
| `0xC0` | last **and** `count == 0` ⇒ the whole message fits in one frame |
| `0x40` | consecutive middle chunk |
| `0x00` | first chunk of a multi-chunk message |

`0xC0` is therefore *not* a magic constant — it is only correct for
single-frame messages.

### 8.3 Incoming call — standard ANS `0x2A46`, **unchunked**

Mi Band 6 does **not** use `onSetCallStateNew` (Bip3/BipS/GTS2/GTR2/ZeppE only).
It inherits `HuamiSupport.onSetCallState` → `AmazfitBipTextNotificationStrategy`:

```
[0x03][0x01] + utf8(caller)   → incoming call
[0x03][0x00]                  → dismiss
```

Notify does byte-for-byte the same (`y5/q.java w()`, `y5/a0.java`).

### 8.4 Icon ids (`HuamiIcon.java`)

`0` WeChat · `1` QQ · `3` Facebook · `4` Twitter · `6` Snapchat · `7` WhatsApp ·
`10` Alarm · **`11` generic app (default)** · `12` Instagram · `13` chat-blue ·
`21` Calendar · `22` FB Messenger/Signal · `23` Viber · `24` Line · `25` Telegram ·
`26` KakaoTalk · `27` Skype · `28` VK · `29` Pokémon GO · `30` Hangouts ·
`34` Email · `35` Weather · `36` HR warning.

Unmapped notification types → `11`. Implemented in `lib/core/huami_icon.dart`.

---

## 9. Band configuration commands

**Sources:** GB `HuamiSupport.java` (`writeToConfiguration` :3816-3823 and the
`set*` methods), `HuamiService.java`, `MiBand6Coordinator.java`.
Implemented in `lib/core/band_config.dart`; every layout is unit-tested.

Mi Band 6 is entirely on the **legacy** config path
(`MiBand6Support → MiBand5Support → MiBand4Support → MiBand3Support →
AmazfitBipSupport → HuamiSupport`). Almost everything is a short opcode-prefixed
write; **the target characteristic is part of the spec** — a command sent to the
wrong one is accepted and silently ignored.

| Target | UUID | Used for |
|---|---|---|
| Configuration | `00000003-0000-3512-2118-0009af100700` | most settings |
| User settings | `00000008-0000-3512-2118-0009af100700` | wear wrist, user info, step goal |
| HR control point | `00002a39-…` (standard) | all HR mode/interval commands |
| Alert level | `00002a06-…` (standard) | vibrate / find band |
| Old chunked | `00000020-0000-3512-2118-0009af100700` | display items, vibration patterns |

### 9.1 Command table

| Setting | Bytes | Target |
|---|---|---|
| Periodic HR interval | `14 <minutes>` (0/1/5/10/30) | HR control |
| HR sleep-assisted | `15 00 <on>` | HR control |
| HR all-day monitoring | `06 22 00 <on>` | config |
| HR high alert | `06 1A 00 <on> <bpm>` | config |
| Stress monitoring | `FE 06 00 <on>` | config |
| Lift wrist off | `06 05 00 00` (4 bytes) | config |
| Lift wrist always | `06 05 00 01 00 00 00 00` (8 bytes) | config |
| Lift wrist scheduled | `06 05 00 01 sH sM eH eM` | config |
| Lift sensitivity | `06 23 00 <0 normal / 1 sensitive>` | config |
| Time format | `06 02 00 <0 =12h / 1 =24h>` | config |
| Date display | `06 0A 00 <0 time / 3 date+time>` | config |
| Date format | `06 1E 00` + 10 ASCII bytes (13 total) | config |
| Distance unit | `06 03 00 <0 metric / 1 imperial>` | config |
| Wear wrist | `20 00 00 <02 left / 82 right>` | **user settings** |
| Step goal | `10 00 00 <lo> <hi> 00 00` (uint16 LE) | **user settings** |
| Goal notification | `06 06 00 <on>` | config |
| DND off / auto / scheduled | `09 82` / `09 83` / `09 81 sH sM eH eM` | config |
| Night mode off / sunset / scheduled | `1A 00` / `1A 02` / `1A 01 sH sM eH eM` | config |
| Inactivity warnings | `08 <on> <threshold> 00 s1H s1M e1H e1M s2H s2M e2H e2M` (12 bytes) | config |
| Vibrate / stop | `03` / `00` | alert level |
| Display items | `1E` + 4 bytes per entry `{index, 00, menuType, itemId}` | chunked type 2 |

Notes that are easy to get wrong:
- **HR interval is in minutes**, not seconds (GB's UI divides by 60 before
  sending). `0` disables periodic measurement.
- **Lift-wrist OFF is 4 bytes; ON is 8** with a zeroed schedule. The 8-byte
  all-zero form means "always", not "disabled".
- **DND + allow-lift-wrist clears bit `0x80`** of byte 1 (`0x81→0x01`,
  `0x83→0x03`).
- Inactivity uses **two** windows so a quiet period can be carved out of the
  middle of the day; with no carve-out, bytes 8-11 stay zero.

### 9.2 Not available on Mi Band 6

| Setting | Why |
|---|---|
| SpO2 all-day monitoring | ZeppOS-only (`ZeppOsConfigService` HEALTH id `0x31`) |
| Sleep-breathing quality | ZeppOS-only (HEALTH id `0x12`) |
| **Low** HR alert | `setHeartrateAlert` encodes only the high threshold |
| Hourly chime | not sent for MB6 |

These are **omitted from the UI**, not shown disabled — a greyed switch implies
the feature is nearly there.

### 9.3 A note on `force_new_protocol`

Gadgetbridge exposes a per-device `force_new_protocol` preference (**default
false**). With it off, GB uses legacy AES-ECB auth and plain config writes; with
it on, both auth *and* config switch to the 2021 chunked path (same payload
bytes, prefixed `0x01`, over endpoint `0x0090`).

Our app is different and deliberately so: this firmware **rejects** the legacy
handshake with status `0x07` (sign-key failed, findings-06), so we authenticate
with the 2021 sign-key flow but keep the **legacy** data/config transport, which
findings-07 verified works on hardware. Config writes therefore go plain to
`0x0003`, not through the chunked endpoint.

---

## Appendix A — Huami-2021 chunked transport (NOT used by MB6; spec for completeness)

Kept because Notify implements it (it supports MB7) and the task asked us to spec
it. Sources: **GB** `Huami2021ChunkedEncoder.java`, `Huami2021ChunkedDecoder.java`,
`InitOperation2021.java`, `CryptoUtils.java`.

- Write `fee0/0x0016`, notify `fee0/0x0017`.
- **First-chunk frame (extended/2021):**
  `03 | flags | 00 | handle | count | len(4 LE) | type(2 LE) | payload…`
  Continuation chunks: `03 | flags | 00 | handle | count | payload…`.
  flags: `0x01` first, `0x02` last, `0x04` needs-ack, `0x08` encrypted.
- **Encryption** (extended+encrypt): `messageKey[i] = sessionKey[i] ^ handle`;
  `plain = data | seqNr(4 LE) | CRC32(data|seqNr)(4 LE)` zero-padded to /16;
  ciphertext = `AES/ECB/NoPadding(messageKey, plain)`; `seqNr++` per message.
- **Session key** from ECDH-B163 auth (endpoint `0x0082`):
  `sessionKey[i] = sharedEC[i+8] ^ authKey[i]`,
  `seqNr = LE32(sharedEC[0..3])`. Double-encrypted-random proof exchange.
- **Decoder** mirrors the encoder; on the last encrypted chunk it AES-decrypts and
  truncates to the declared length, then dispatches by `type`.

> If a *future* device (or a firmware that rejects legacy HR) turns out to need
> this, the `Huami2021Chunked` Dart class can be implemented from this appendix.
> For Mi Band 6 it is intentionally **not** wired up.
