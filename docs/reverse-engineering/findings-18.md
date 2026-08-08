# findings-18 — Sleep accuracy: rebuilt session detection and staging

**Date:** 2026-08-09
**Scope:** `lib/core/sleep_analyzer.dart` (new) + `ActivityStore.computeSleepDays`
delegation + Gate 7. **No protocol bytes changed** — no new command is written
to the band. `flutter analyze` clean; `flutter test` 126/126 (+25 new).

> Not hardware-verified: no adb device this session. The checks that decide
> whether the numbers are *right* (rather than merely self-consistent) are
> queued as §P2 in `pending-hardware-verification.md` — above all P2.3, the
> minute-by-minute comparison against Zepp Life for the same night.

---

## 1. What was wrong

### 1.1 The stage table was for the wrong device family

`SleepStage.fromCategory` mapped categories **112 / 121 / 122 / 126 / 128**.
Those are (approximately) `HuamiExtendedSampleProvider`'s raw kinds — and that
provider is instantiated **only by `ZeppOsCoordinator`**
(`ZeppOsCoordinator.java:314-316`). Mi Band 6 is not a ZeppOS device:
`MiBand6Coordinator extends HuamiCoordinator` and never overrides
`getSampleProvider()`, so it uses `MiBand2SampleProvider` →
`HuamiConst.toActivityKind`, whose sleep kinds are **9 (light)** and
**11 (deep)**.

So the mapping never matched anything. The code then silently fell through to a
`sleep`-byte heuristic and a hand-tuned `deepSleep & 0x7F > 52` cut.

### 1.2 Not-worn was guessed

The old pipeline had no not-worn concept at all, and the brief for this work
assumed it was `intensity == 0xFF`. It is not: Gadgetbridge detects not-worn
purely from the kind value — **3 (nonwear)** and **6 (charging)**
(`HuamiConst.java:134-137`). `intensity == 0xFF` appears nowhere. This matters
because a band on a nightstand is perfectly still and reads as flawless sleep.

### 1.3 Session stitching didn't match the reference

| | Old (`activity_store`) | Gadgetbridge |
|---|---|---|
| Merge gap | 60 min | 60 min max wake gap ✓ |
| Min session | 25 min span / 20 min sleep | **5 min** |
| Steps | ignored | **any stepped minute breaks the session** |
| Day boundary | `date` of session end | **18:00 → 18:00 window** |
| Over-merge guard | drop sessions > 12 h | (splitting handles it) |

The missing 18:00 rule is what made midnight crossover fragile, and ignoring
steps let an evening of stillness bridge into the night.

### 1.4 Stage split was apportioned, not measured

`_buildSleepDayFromWindow` computed each stage's minutes as
`spanMinutes × (samples in stage) / (samples in window)`. Because the band's
sampling cadence is irregular, that silently converted "more samples" into "more
minutes". Durations were never measured from the clock.

---

## 2. What it does now

`SleepAnalyzer.detectSessions(samples, hr:)` — pure, no clock reads, fully
unit-tested.

### 2.1 Classification

- `maskedKind(category) = category & 0x0F` (GB masks before comparing; the high
  nibble carries flags).
- Kind **9** → light, **11** → deep, **3/6** → not worn, **0/10** → carry
  forward, steps > 0 → awake.
- **REM is never produced.** The legacy mapping has no REM case,
  `MiBand6Coordinator` reports `supportsRemSleep() == false`, and findings-09
  showed byte 7 is identically 0 on this firmware. Gate 7 fails the session if
  any REM appears, so this cannot regress into an invented metric.

### 2.2 Hardware disagrees with the reference — and hardware wins

Our captures show this firmware never emits kind 9 or 11: overnight bytes are
`0xF3`/`0xF0`, daytime `0x50`. Masked, those are 3/0/0 — "not worn" — which is
obviously wrong for a night's sleep.

Rather than pick a side, `_isAsleepSample` honours **both**: an explicit 9/11
kind is authoritative where present, otherwise the `sleep` byte (offset 5) is
the asleep gate — which findings-09 verified maps 1:1 to the 0xF0/0xF3 values.
**Gate 7 now logs the kind-byte histogram** so one hardware run settles the
question (P2.1), instead of it staying a guess.

### 2.3 Sessions

5-minute minimum, 60-minute maximum wake gap, stepped minutes break the session,
and `sleepDayFor()` implements the 18:00 boundary — so a 23:30 bedtime is
attributed to the following morning. It works on local wall-clock fields rather
than elapsed milliseconds, so a DST transition cannot shift a night by an hour.

Data gaps are honoured: a hole longer than 10 minutes ends the interval at the
last real sample instead of stretching sleep across un-synced time.

### 2.4 Off-wrist rejection

Two independent guards:
1. more than half the window not-worn ⇒ not a session;
2. HR data exists elsewhere but **none at all** inside a session of ≥1 h ⇒ the
   band was off the wrist.

### 2.5 Staging from heart rate

Deep sleep is no longer a byte threshold. It requires a **sustained dip ≥ 6 %
below the session's own median HR for ≥ 8 consecutive minutes**.

- Per-user baseline (median, so motion artefacts cannot drag it), not an
  absolute bpm.
- Deliberately conservative: a flat HR trace yields **zero** deep sleep rather
  than a plausible-looking guess (test: "a flat heart rate yields no deep sleep").

Movement scoring uses a **Cole–Kripke**-shaped weighted window (Cole, Kripke,
Gruen, Mullaney & Gillin, "Automatic sleep/wake identification from wrist
activity", *Sleep* 1992;15(5):461-9) over the band's per-minute intensity, so an
isolated twitch cannot create a wake episode while sustained movement does. The
HR-dip rule follows the approach used in consumer-wearable validation work
(e.g. de Zambotti et al.). Both are applied as **priors over the band's own
signal**, and both are labelled estimates in the code.

### 2.6 Quality metrics — `SleepQuality`

Efficiency, latency, wake episodes, time in bed.

**Latency needed a definition, not just a calculation.** The band cannot tell us
when someone got into bed, so latency measured from sleep onset is always zero.
Actigraphy measures it from **rest onset**, so `_restOnset` walks back over
contiguous worn, non-stepping, low-movement samples, capped at 60 minutes — a
quiet evening on the sofa cannot become "an hour trying to fall asleep".
Efficiency is not clamped: a value over 100 would indicate a bug, and hiding it
would hide the bug.

Wake episodes count only awakenings **between** sleep — leading wake is latency,
trailing wake is the morning.

---

## 3. Stages fetch (0x48): confirmed absent, with evidence

`FetchSleepSessionOperation` (594-byte records with a full stage timeline and the
band's own sleep score) is gated on `coordinator.supportsSleepScore()`, which only
`ZeppOsCoordinator` returns true for. Independently — and more convincingly — we
**probed the band directly** in findings-09: fetch type `0x48` was *accepted* and
answered `expected data length = 0`. Same for `SLEEP_RESPIRATORY_RATE` (0x38).

So: the type exists on the wire, the band simply holds no such records. There is
nothing to implement, and stages must come from the per-minute stream. Documented
in `protocol-mb6.md` §7.4.

---

## 4. Verified here

| Claim | Evidence (`test/sleep_analyzer_test.dart`) |
|---|---|
| Kind nibble masking | `0xF3→3`, `0x50→0`, 9/11 preserved |
| Not-worn from kind, not intensity 0xFF | explicit negative assertion |
| HR validity 10..250 (0xFF rejected) | boundary tests |
| Midnight crossover → next day | 23:30 → date is the 9th |
| 18:00 boundary | three `sleepDayFor` cases |
| >60 min gap splits sessions | two sessions from one array |
| Short awakening stays in one night | one session, awake minutes > 0 |
| Stepped minute is not sleep | awake minutes appear |
| Desk band rejected | not-worn window → no session |
| Still band with no HR rejected | HR elsewhere, none in window |
| Sustained dip → deep; flat → none; 1-min dip → none | three staging tests |
| REM always 0 | explicit test + Gate 7 assertion |
| Data gap not filled in as sleep | totals < wall-clock span |
| Naps separated from nights | `isNap`, no night totals |
| Duplicates / unsorted / DST | robustness group |

`computeSleepDaysLegacy()` is retained (test-only) so the old and new pipelines
can be diffed over the same captured file during P2.6.

## 5. Honest limits

- **None of this proves the numbers are right.** The tests prove internal
  consistency and edge-case handling. Only P2.3 (minute-by-minute vs Zepp Life)
  can establish accuracy.
- The 6 % / 8-minute deep-sleep rule and the Cole–Kripke threshold (120 on the
  band's 0-255 intensity scale) are calibrated by reasoning, not by fitting
  against scored data. They are named constants, easy to retune once P2.3 exists.
- The 60-minute rest-onset look-back is a modelling choice; a genuinely long
  time falling asleep will be reported as at most 60 minutes.
- The kind-byte contradiction (§2.2) is **unresolved**. Until P2.1 runs, the
  analyzer depends on the `sleep` byte, which is evidence-backed for this one
  firmware version but may not hold across others.
