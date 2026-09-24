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

**Data-type byte (2nd byte of start cmd)**, from `HuamiFetchDataType.java:20-36`:
`01`=activity (steps+HR+intensity+sleep, 8-byte stream), `02`=MANUAL_HEART_RATE,
`05`=SPORTS_SUMMARIES, `07`=DEBUG_LOGS, `0D`=PAI, `12`=stress manual,
`13`=stress all-day, **`25`=SpO2**, `26`=SpO2 variant, `48`=SLEEP_SESSION.
⚠️ An earlier version of this table said `05`=HR history and `0D`=sleep; both
contradicted the GB enum it cited (findings-23 §D11). ⚠️ `0x12` is **stress**,
not SpO2 — that was wrong in the old code.

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
| 9 | TYPE_LIGHT_SLEEP | light sleep — ⚠️ **only inside the `0xF` flag**, see below |
| 10 | TYPE_IGNORE | *carry forward previous valid kind* |
| 11 | TYPE_DEEP_SLEEP | ⚠️ **not deep sleep** — sleep onset; see findings-21 §9.1 |
| 12 | TYPE_WAKE_UP | activity (**not** a sleep kind) |

> **⚠️ Kinds 9 and 11 do not mean sleep on their own** (findings-23 §1).
> 207 of 823 kind-9/11 samples in a 69 419-sample capture — a quarter — carry a
> non-`0xF` high nibble; their median HR is 73 against 65 for `0xF0`, half have
> intensity ≥ 20, and 62 fall between 08:00 and 10:00. That is waking movement.
> Three such samples were enough to stitch one night across two 70-minute wake
> gaps and inflate its "time in bed" by 2h 12m. The analyzer now takes the
> `0xF` high nibble as the *only* sleep signal, and reads depth from heart rate
> alone. findings-21 §9.1 had already retired kind 11 as "deep"; this extends
> that to kind 9.

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

### 7.2 ✅ RESOLVED on hardware — the byte has two independent halves

**Settled 2026-08-10 against 60 404 real samples over 53 days** (findings-21).
The earlier contradiction was a misreading: the kind byte is not one value, it is
**two independent nibbles**, and both carry meaning.

```
   category byte
   ┌───────┬───────┐
   │ high  │  low  │
   └───────┴───────┘
      │        └── HuamiConst kind (3 = NONWEAR, 6 = CHARGING, 9 = LIGHT,
      │            11 = DEEP, 0/10 = carry forward, 1/2 = activity)
      └─────────── 0xF = ASLEEP, anything else = awake/activity
```

**High nibble `0xF` is the sleep flag.** Share of samples carrying it, by hour:

| 00 | 02 | 04 | 06 | 08 | 12 | 16 | 20 |
|---|---|---|---|---|---|---|---|
| 18.9 % | 84.2 % | **96.8 %** | **98.6 %** | 67.4 % | 8.2 % | 6.1 % | 3.3 % |

and it separates on physiology, which is the real proof:

| | high nibble `0xF` | everything else |
|---|---|---|
| median heart rate (valid) | **65 bpm** | **81 bpm** |
| median movement intensity | 0 | 32 |

A ~20 % nocturnal heart-rate dip with no movement is what sleep looks like.

**Low nibble 3 means the band recorded nothing — at any hour.** The decisive
measurement is heart-rate coverage, because a worn band measures a pulse:

| kind | samples | with a valid heart rate |
|---|---|---|
| `0xF0` | 7 619 | **99.6 %** |
| `0xF9` | 504 | 98.2 % |
| `0x50` | 24 306 | 96.8 % |
| `0x60` | 8 644 | 95.9 % |
| **`0xF3`** | 7 654 | **0.04 %** |
| **`0x73`** | 1 572 | **0.13 %** |

`0xF3` at night is *not* sleep; it is the not-worn/no-measurement state inside a
sleep context. Split by time of day it is 0.0 % HR coverage both at 01:00-08:00
and at 10:00-18:00 — the same state either way.

So Gadgetbridge's `HuamiConst` table was right all along about the **low** nibble;
what it does not model is the high nibble, which it explicitly treats as unknown
flags (`determinePreviousValidActivityType` skips 16, 80, 96, 112 with the
comment "all I ever had that are 0 when doing &=0xf" — i.e. `0x10, 0x50, 0x60,
0x70`).

**The correct rule:**

```
asleep  ⇔  (category >> 4) & 0x0F == 0xF
           AND (category & 0x0F) ∉ {3, 6}
           AND steps == 0
```

Sanity check on the same data: median **444 samples/day ≈ 7.4 h/night**, with
99.6 % heart-rate coverage and a median sleep heart rate of 65 bpm.

### 7.2b The `sleep` byte (offset 5) is not a boolean

It carries **56-62 during sleep and 0-2 during the day**. Any `> 0` test leaks:
measured against the high-nibble flag, `sleep > 0` marked **10 831 extra
samples** as asleep, concentrated at 20:00-00:00, 580 of them with a non-zero
step count — inflating reported sleep by ~30 %. Do not use it as a gate.

### 7.2c The `deepSleep` byte (offset 6) carries no stage information

Mean heart rate by `ds & 0x7F` bucket across 16 228 sleep samples:

| bucket | 0-9 | 30-39 | 40-49 | 50-59 | 60-69 | 70-79 | 80-89 | 90-99 |
|---|---|---|---|---|---|---|---|---|
| mean HR | 75.4 | 66.1 | 66.6 | 66.6 | 65.9 | 67.1 | 67.6 | 65.9 |

Flat. Deep sleep must show a **lower** heart rate; this shows none. Nor does any
sub-state cluster early in the night as slow-wave sleep should. The
`deepSleep & 0x7F > 52` rule from findings-09 was separating noise, and deep/light
must be derived from heart rate instead (see `lib/core/sleep_analyzer.dart`).

`remSleep` (offset 7) is identically 0 — confirmed again here. **No REM.**

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

**When** these are written matters as much as the bytes: once per ringing
call, on the phone's telephony state — never on the dialer's notification.
See §12.4.

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

## 10. Stress (native, measured by the band)

**Sources:** GB `FetchStressAutoOperation`, `FetchStressManualOperation`,
`HuamiFetchDataType`, `HuamiSupport.setHeartrateStressMonitoring`,
`MiBand6Coordinator.supportsStressMeasurement()`; cross-checked against Notify
and Mi Fit (`MiLiProProfile` — Xiaomi calls stress "pressure"). See
`findings-20.md`.

Mi Band 6 **computes stress on-device**, entirely on the legacy path. Both types
ride the ordinary activity-fetch channel (write `fee0/0x0004`, notify
`fee0/0x0005`).

> ### ⚠️ HARDWARE DISAGREES — the table below has never been observed on the wire
>
> Every buffer this app has received for `0x13` and `0x12` decodes as the
> **8-byte-per-minute activity stream**, not as stress (findings-23). Parsed at
> one byte per minute the clock ran eight times fast, so 63% of the stored
> readings were dated *after* the moment they were fetched; the manual records
> were smeared across 1970-2105, and one hand-decodes to `00 7c 00 00 40`, i.e.
> its "stress score of 64" is that minute's heart-rate byte.
>
> **Unresolved:** whether the band serves activity for these types, or whether
> our own `0x01` transfer leaks into the stress buffer. **Probe P1** in
> `pending-hardware-verification.md` distinguishes them.
>
> Ingest is gated behind `BLEManager.kStressFetchVerified` (false) and the app
> falls back to a labelled heart-rate estimate. The layouts below stay
> documented — they remain the correct target if P1 succeeds.

| Type | Meaning | Payload (per GB — **unconfirmed on this band**) |
|---|---|---|
| `0x13` | all-day / automatic | bare stream, **1 byte per minute**, 0-100, `0xFF` = no measurement |
| `0x12` | manual / spot | **5-byte records**: `uint32 LE` epoch-seconds + `uint8` score |

Neither has a version byte — unlike SpO2 (`0x25`), which starts with one.

**`0xFF` still consumes its minute.** Skipping a gap instead of advancing the
clock would shift every later reading earlier.

Enable all-day recording with `FE 06 00 01` on the config characteristic
(`00000003-…`); disable with `FE 06 00 00`. Mi Fit also exposes a read-back
getter `FE 06 01`. With monitoring off the band simply holds no records, which
is a configuration state rather than a protocol failure.

## 11. Realtime HR flags byte — and the absence of RR intervals

The Heart Rate Measurement characteristic `0x2A37` carries a flags byte that
both Gadgetbridge's Huami path and our old code ignored
(`HuamiSupport.handleHeartrate` hard-guards `length == 2 && value[0] == 0`;
we did `data[1] & 0xFF`).

Correct layout (Bluetooth SIG Heart Rate Service):

| bit | meaning |
|---|---|
| 0 | 0 = HR uint8, 1 = HR uint16 LE |
| 1-2 | sensor contact (supported / detected) |
| 3 | energy expended present (uint16 LE, kJ) |
| 4 | **RR intervals present** (N × uint16 LE, units of 1/1024 s) |

Now decoded fully in `lib/core/heart_rate_measurement.dart`.

**Finding: this firmware does not send RR intervals.** All 34 captured
notifications across 8 hardware runs are exactly 2 bytes with flags `0x00`
(bit 4 clear). Consequently **real HRV (RMSSD/SDNN) cannot be computed from the
realtime stream**, and any "HRV" derived from BPM alone would be fiction. The
HRV fetch type `0x49` is likewise gated on `supportsHrvMeasurement()`, which only
`ZeppOsCoordinator` overrides — GB never sends it to a Mi Band 6.

The parser now logs loudly if RR intervals ever do appear, so the conclusion can
be revisited rather than assumed permanent.

## 12. Device events — the band talking to the phone (`fee0/0x0010`)

The band pushes short event frames on **`00000010-0000-3512-2118-0009af100700`**
(`UUID_CHARACTERISTIC_DEVICEEVENT`, **GB** `HuamiService.java:52`). This is
how every band-side button — reject a call, find my phone, silent mode — reaches
the app, and it also carries the band's *own* sleep-onset and wake-up
determinations.

**Subscribe only after authentication.** GB enables the CCCD in
`enableFurtherNotifications` (**GB** `HuamiSupport.java:544-554`, line 549 for
0x0010), which runs only on `AUTH_SUCCESS` (`InitOperation2021.java:160-173`,
line 167). `enableNotifications` (pre-auth, `:533-542`) never touches it.

Dispatch is on `value[0]` (**GB** `HuamiSupport.java:1705-1842`, switch at
`:1711`). Constants from **GB** `HuamiDeviceEvent.java:20-38`, verbatim:

| `value[0]` | Name | Payload | GB action (`HuamiSupport.java`) | Ours |
|---|---|---|---|---|
| `0x01` | FELL_ASLEEP | — | `SleepState.ASLEEP` (`:1741-1744`) | recorded as a sleep-boundary event |
| `0x02` | WOKE_UP | — | `SleepState.AWAKE` (`:1745-1748`) | recorded as a sleep-boundary event |
| `0x03` | STEPSGOAL_REACHED | — | log only (`:1749-1751`) | log |
| `0x04` | BUTTON_PRESSED | — | `handleButtonEvent()` (`:1722-1725`) | log (no mapping yet) |
| `0x06` | START_NONWEAR | — | `WearingState.NOT_WEARING` (`:1730-1733`) | recorded as wear event |
| `0x07` | **CALL_REJECT** | — | `GBDeviceEventCallControl.REJECT` (`:1712-1716`) | end the call — §12.1 |
| `0x08` | FIND_PHONE_START | — | ack + `FindPhone.START` (`:1755-1760`) | ack (§12.2) + ring the phone |
| `0x09` | **CALL_IGNORE** | — | `CallControl.IGNORE` (`:1717-1721`) | silence the ringer — §12.1 |
| `0x0a` | ALARM_TOGGLED | — | `requestAlarms` (`:1734-1740`) | log |
| `0x0b` | BUTTON_PRESSED_LONG | — | `handleLongButtonEvent()` (`:1726-1729`) | log |
| `0x0e` | TICK_30MIN | — | log only (`:1752-1754`), GB itself marks it "unsure" | log |
| `0x0f` | FIND_PHONE_STOP | — | `FindPhone.STOP` (`:1761-1765`) | stop ringing |
| `0x10` | SILENT_MODE | `value[1]`: 1 = on | echo to band (`:1766-1771`, `:2002-2006`) | log (phone DND needs a policy grant) |
| `0x14` | WORKOUT_STARTING | `value[2]` needsGps, `value[3]` type | (`:1821-1838`) | log |
| `0x16` | MTU_REQUEST | `value[1..2]` uint16 LE | (`:1807-1820`) | log |
| `0x1a` | ALARM_CHANGED | — | `requestAlarms` (`:1734-1740`) | log |
| `0xfe` | MUSIC_CONTROL | `value[1]`: 0 play, 1 pause, 3 next, 4 prev, 5 vol+, 6 vol−, 0xe0 app open, 0xe1 app closed (`:1776-1801`) | media keys | log (not wired) |

Codes `0x05`, `0x0c`, `0x0d` are undefined. **There is no quick-reply / reply-index
event on this characteristic** in GB — see §13.

### 12.1 Call reject and ignore → phone

GB maps `0x07` to `TelecomManager.endCall()` and `0x09` to a mute broadcast
(**GB** `GBDeviceEventCallControl.java:43-57`, `GBCallControlReceiver.java:80-85`;
`tm.endCall()` at `:83`; pre-API-28 reflective `ITelephony.endCall()` at `:53-73`).

What the mute broadcast actually does (**GB** `PhoneCallReceiver.java`,
`MUTE_CALL` branch): only if the phone is `CALL_STATE_RINGING`, save
`AudioManager.getRingerMode()`, set `RINGER_MODE_SILENT`, and restore the saved
mode when the state returns to `IDLE`. Notify does the same on Android 10+
(`i9/j.java G()`: `setRingerMode(0)` with a 90 s fallback restore); below 10 it
also tries the hidden `ITelephony.silenceRinger()`. Mi Fit's
`IncomingCallAlertActivity` likewise goes through the ringer mode. None of them
use `TelecomManager.silenceRinger()`, which needs `MODIFY_PHONE_STATE` — a
signature permission. And since Android N, changing the ringer mode to silent
(or muting `STREAM_RING` far enough to flip it) throws
`SecurityException: Not allowed to change Do Not Disturb state` unless the app
holds **Notification Policy ("Do Not Disturb") access**, granted on a system
page rather than through a runtime dialog.

Ours: `CallControlHost.kt` — `endCall` via `TelecomManager.endCall()`
(`ANSWER_PHONE_CALLS`, API 28+); `silenceRinger` delegates to
`CallStateHost.silence()`: ringer mode → silent while ringing, restored on
`IDLE`, needs DND access (Settings › Band buttons › *Silence from the band*).
Both return whether the action happened. The earlier version tried
`TelecomManager.silenceRinger()` then a `STREAM_RING` mute; both threw and were
swallowed, so Silence on the band never did anything.

### 12.2 Find-phone acknowledgement

On `0x08` GB writes `COMMAND_ACK_FIND_PHONE_IN_PROGRESS` to `0x0003`
(**GB** `HuamiSupport.java:1975-1984`, `AmazfitBipService.java:32`):

```
06 14 00 00        → fee0/0x0003   (ENDPOINT_DISPLAY=0x06, HuamiService.java:148)
```

GB's own comment on the call site reads `// FIXME: premature`. Ours sends the
same bytes and starts ringing the phone; `0x0f` stops it.

### 12.4 Call state comes from telephony, not from the dialer's notification

Every reference implementation decides "a call is ringing" from
`TelephonyManager` call state, never from a notification:

* **GB** `PhoneCallReceiver.onCallStateChanged` — `RINGING` → `CALL_INCOMING`;
  `OFFHOOK` after `RINGING` → `CALL_START`, otherwise `CALL_OUTGOING`; `IDLE` →
  `CALL_END`; the same state twice is ignored. `HuamiSupport.onSetCallState`
  (`:1222-1238`) writes the alert only for `CALL_INCOMING`, and `03 00` on
  `CALL_START`/`CALL_END`. `CALL_OUTGOING` does nothing.
* **Mi Fit** `com.xiaomi.hm.health.receiver.PhoneStateReceiver` — the
  `PHONE_STATE` broadcast: `EXTRA_STATE_RINGING` → alert (after the
  user's configurable delay), `OFFHOOK`/`IDLE` → stop.
* **Notify** `i9/j.java` — a `PhoneStateListener.onCallStateChanged`, same
  three states.

Our first version keyed off the dialer's `CATEGORY_CALL` notification instead,
and re-sent `03 01 <caller>` on every post of it. That notification is posted
for outgoing calls, and re-posted every time the call timer ticks, the call
goes on hold or the audio route changes — so the band buzzed on dialling and
kept buzzing mid-conversation, each buzz replacing the screen whose buttons had
just been pressed. See findings-27.

Now: `CallStateHost.kt` registers a `TelephonyCallback.CallStateListener`
(API 31+; `PhoneStateListener` below) on the process-lifetime engine and
reports transitions as `ringing` / `answered` / `outgoing` / `ended` on
`band/call_state`. `CallSession` (Dart) writes the alert once per `ringing`,
and `03 00` on `answered` or `ended`. The notification is consulted only for
the caller's name and number, because the telephony callback carries no number
on API 31+. Needs `READ_PHONE_STATE`.

### 12.3 Silent-mode echo (spec only — not sent by us)

```
06 19 00 <00|01>   → fee0/0x0003   (HuamiSupport.java:2002-2006)
```

Toggling the phone's own DND from the band needs Notification Policy access,
which this app does not request. Logged, not actioned.

---

## 13. Canned replies to rejected calls — **UNVERIFIED on Mi Band 6, off by default**

Everything in this section is a documented *possibility*, not a verified path,
and the app ships it behind a switch that defaults off with the word
"experimental" on it. Reasons, all from **GB**:

1. The only outbound implementation is `HuamiSupport.onSetCannedMessages`
   (`HuamiSupport.java:1277-1305`), over the **chunked-2021** transport
   (`writeToChunked2021`, `:3798-3800`), endpoint `0x0013`. This band does use
   that transport for auth, so the bytes are *plausible*.
2. The **only inbound path is hard-disabled upstream**:
   `if (type == ZeppOsCannedMessagesService.ENDPOINT && false) { // unsafe for now, disabled`
   (`HuamiSupport.java:3979`).
3. `MiBand6Coordinator.getDeviceSpecificSettings` (`MiBand6Coordinator.java:106-145`)
   does not add the canned-message preference, so GB never exposes it for MB6.

### 13.1 Outbound — set the list (endpoint `0x0013`, chunked-2021, unencrypted)

Delete all 16 slots, then create (**GB** `HuamiSupport.java:1282-1298`):

```
delete:  07 | handle(uint32 LE)                       5 bytes, ×16, handle from 0x12345678, +1 each
create:  05 | handle(uint32 LE) | text bytes | 00     len+6 bytes, handle from 0x12345678, +1 each
```

`CMD_SET=0x05`, `CMD_DELETE=0x07` (**GB** `ZeppOsCannedMessagesService.java:52,54`).
Text is `String.getBytes()` — platform default charset, i.e. UTF-8 on Android.
**Note** the ZeppOS frame differs (`05 | index | len | 00 | text`, `:124-132`)
and is not interchangeable.

### 13.2 Inbound — the chosen reply (endpoint `0x0013`, on `0x0017`)

From the disabled block (**GB** `HuamiSupport.java:3981-4011`):

```
0d                               → we reply  0e 01  (CMD_REPLY_SMS_ALLOW)
0b | number ASCII | 00 | 4 unknown bytes | reply text | 1 trailing byte
                                 → we reply  0c 01  (CMD_REPLY_SMS_ACK)
```

**The band sends the full reply text and the caller's number, not an index.**

Ours, when the experimental switch is on: parse `0x0b`, end the call, send the
SMS via `SmsManager` (`SEND_SMS`), ack with `0c 01`. Probe **P13.1** records the
hardware outcome.

### 13.3 Decline-with-text without the band (phone-side, always available)

Independent of §13.1-13.2: on `0x07` CALL_REJECT, if the user has enabled
"reply with a text when I decline from the band", the app ends the call and
sends the preset message to the caller's number when the incoming-call
notification carried one. No new band bytes are involved.

---

## 14. SpO2 — no phone-triggered measurement exists on this firmware path

Searched for tonight's "periodic SpO2 trigger" request; recording the negative
result so it is not searched for again.

- **GB:** `grep -i spo2` over `HuamiSupport.java`, `MiBand6Support.java`,
  `MiBand5Support.java` → zero matches. There is no `onSpo2Test` analogue to
  `onHeartRateTest` (`HuamiSupport.java:1508-1523`). `MiBand6Coordinator` does
  not override `supportsSpo2` (`DeviceCoordinator.java:319`, default false at
  `AbstractDeviceCoordinator.java:764-767`), so GB neither triggers *nor fetches*
  SpO2 for this band.
- **NOTIFY:** the decompile references SpO2 only in UI resources and a data
  model; no command builder targeting a band characteristic was found (§14.1
  below records what was checked).
- **What exists:** the *history* fetch, type `0x25` (`HuamiFetchDataType.java:28`),
  `01 25 <time>` to `0x0004`, 65-byte records `ts(uint32) | spo2raw | 60 bytes`,
  where bit 7 of `spo2raw` set = automatic (`FetchSpo2NormalOperation.java:82-83`).
  We already fetch this; it returns whatever the user measures on the band.

Conclusion: **a one-shot measurement cannot be triggered from the phone with any
command this project can cite.** The app keeps fetching the band's own readings
(P14.1 stays open for a trigger command).

### 14.1 Probe — switch on the band's *automatic* SpO2 monitoring (P14.2)

Not a trigger: a setting that asks the band to sample SpO2 on its own, which is
what "periodic blood oxygen" would actually mean on this hardware. **Unverified
on Mi Band 6; off by default; experimental.**

Two independent sources agree on the setting's existence; neither proves the
band honours it:

- **NOTIFY** `h6/a.java:245` declares `SPO2_ALL_DAY_MONITORING` (code 49 =
  `0x31`) and `x5/f.java:2988` sends it via a config writer alongside
  `STRESS_MONITORING` and `SLEEP_BREATHING_QUALITY_MONITORING`. Whether that
  code path is reached for a Mi Band 6 is not established (it sits behind a
  device-capability lookup, `f22183r.b(10)`).
- **GB** `ZeppOsConfigService.java:525` — `SPO2_ALL_DAY_MONITORING(HEALTH, BOOL,
  0x31)`. GB only ever sends it to ZeppOS devices; `MiBand6Coordinator` does
  not enable it.

Frame, from **GB** `ZeppOsConfigService.encode` (`:940-955`), `ConfigGroup.HEALTH
= (0x08, version 0x03)` (`:399`), `ConfigType.BOOL = 0x0b` (`:433`), `CMD_SET =
0x05` (`:110`), endpoint `0x000a` (`:104`), **encrypted** (`:116`, `super(support,
true)`; `AbstractZeppOsService.write` → `writeToChunked2021(..., isEncrypted())`):

```
05 08 03 00 01 31 0b 01    → chunked-2021 endpoint 0x000a, encrypted
│  │  │  │  │  │  │  └─ value: 1 = on
│  │  │  │  │  │  └──── type BOOL
│  │  │  │  │  └─────── arg SPO2_ALL_DAY_MONITORING
│  │  │  │  └────────── argument count
│  │  │  └───────────── 0x00 (GB: "?")
│  │  └──────────────── HEALTH group version
│  └─────────────────── HEALTH group
└────────────────────── CMD_SET
```

Expected reply on `0x0017`, endpoint `0x000a`: `06 …` (`CMD_ACK`, `:111`).

Pass criterion for P14.2: the ack arrives **and** subsequent `0x25` fetches
return records with bit 7 of `spo2raw` **set** (= automatic,
`FetchSpo2NormalOperation.java:82`) at times the user did not measure by hand.
Either half alone proves nothing.

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
