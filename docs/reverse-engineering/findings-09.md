# findings-09 — Sleep-stage decode on MB6 (deep-byte mask; no REM/0x48)

**Date:** 2026-06-26
**Symptom:** stage split was physiologically impossible — Deep 6 m, Light 8 h13 m
(98 %), REM 2 m for an 8 h21 m night. Same class of bug as SpO2 (findings-08):
a wrong byte interpretation.

## What the old code did

`_sessionStage` classified, *within a detected sleep block*: `sleep` byte > 0 →
light, else → deep. Since almost every in-session sample has `sleep > 0`, deep
was ~0 and light ~98 %.

## Investigation (Gadgetbridge + real bytes)

### 1. Is there a dedicated sleep-session stream? (0x48)
Gadgetbridge `HuamiFetchDataType` lists `SLEEP_SESSION(0x48)` (594-byte records
with a full stage timeline + the band's own score). Implemented a temporary
probe (`captureSleepSessionRaw`) and fetched 0x48 over adb:

```
requesting data type 0x48 since 2026-06-19 …
expected data length = 0
SLEEPSESSRAW len=0
```

→ **MB6 (MILI_PANGU) returns no 0x48 data.** The band accepted the request but
has zero sleep-session records — dedicated sleep sessions are a newer
Amazfit/Zepp feature. So stages must come from the per-minute activity stream.

### 2. How does GB derive stages from the activity stream?
`HuamiExtendedSampleProvider` overlays 0x48 stages when present; otherwise it
falls back to the per-sample bytes (this is MB6's path):

```java
if (sample.getRawKind() == TYPE_SLEEP) {           // TYPE_SLEEP = 120
    deep = sample.getDeepSleep() & 127;            // byte 6, masked
    rem  = sample.getRemSleep()  & 127;            // byte 7, masked
    if (rem > 55) -> REM; else if (deep > 42) -> DEEP; else -> LIGHT;
}
```

Sample byte map (GB `createExtendedSample`, identical to ours):
`[0]kind [1]intensity [2]steps [3]hr [4]unknown1 [5]sleep [6]deepSleep [7]remSleep`.

### 3. Hand-decode of real MB6 bytes (evidence)
Re-pulled `activity_data.json` (bytes 0,5,6,7 are stored as `c,sl,ds,rs`):

- **byte 0 (kind) is never 120 on MB6.** At 01–07 h it is `0xF3`(243) / `0xF0`(240);
  daytime is `0x50`(80). So MB6 marks sleep with `240/243`, not GB's `TYPE_SLEEP`.
  These map 1:1 to `sleep>0`, so `sleep(byte5) > 0` is our reliable "asleep" gate.
- **byte 7 (remSleep) is `0x00` for every sample** → MB6 does not encode REM in
  the activity stream. GB's `rem > 55` can never fire. **REM is not available.**
- **byte 6 (deepSleep):** the masked (`&0x7F`) values are **bimodal** — a
  light-sleep baseline cluster (~33–52, modes 33/37/43) and an elevated deep tail
  (55/70/90/100). GB's Amazfit-tuned cut (`> 42`) lands *inside* the baseline
  cluster and over-counts deep (42 % on one MB6 night — implausible). Cutting at
  the cluster edge (**`> 52`**) separates the tail and yields ~13–18 % deep on
  night-by-night data — within the healthy 13–23 % range.

## Fix

`_sessionStage` derives deep from `deepSleep & 0x7F > 52` (data-driven cut for
MB6, not GB's 42) instead of `sleep == 0`. On hardware the selected night went
from Deep 6 m (98 % light) → **Deep 1 h23 m (17 %), Light 83 %** with multiple
visible cycles in the hypnogram.

This is an **estimate**, surfaced as such in the UI ("Estimated — this band
reports deep vs light sleep but does not track REM separately"). REM is dropped
from the stage cards and the score (never fabricated from the always-zero REM
byte); it is only shown if an explicit REM sleep category appears.

## Honest limitation (documented, not faked)

MB6's activity stream tracks **deep vs light(+core)** but **not REM** (byte 7 ≡ 0)
and has no 0x48 session stream. So REM reads ~0; "Light" effectively includes
REM/core. This is a hardware/firmware limit of the band, surfaced to the user —
not a parser bug and not estimated.

No BLE/auth/fetch-transport changes — byte interpretation only.
