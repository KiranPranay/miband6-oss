# findings-21 — The sleep encoding, settled on 60 404 real samples

**Date:** 2026-08-10
**Device:** Pixel 9a (`55211XEBF1RB28`) + Mi Band 6, worn overnight.
**Data:** `activity_data.json`, 60 404 samples, 2026-06-18 → 2026-08-10 (53 days),
plus 60 578 heart-rate readings.

This closes the open contradiction in `protocol-mb6.md` §7.2 (**P2.1**), and in
doing so found three separate defects in the shipping sleep pipeline. All three
are fixed and re-validated against the same data.

---

## 1. The contradiction was a misreading

findings-09 recorded that this firmware "never emits kind 9 or 11 — overnight
samples carry `0xF3`/`0xF0`, daytime `0x50`", and concluded Gadgetbridge's table
did not apply. Masking with `& 0x0F` turned those into 3/0/0 — "not worn" and
"no change" — which is obviously wrong for a night of sleep, so the analyzer fell
back to the `sleep` byte.

The byte is **two independent nibbles**:

```
high nibble 0xF  = ASLEEP
low  nibble      = HuamiConst kind (3 NONWEAR, 6 CHARGING, 9 LIGHT, 11 DEEP, …)
```

Gadgetbridge models only the low half and openly treats the high half as
unknown flags. Both halves are real.

### Evidence — the flag

| hour | 00 | 02 | 04 | 06 | 08 | 12 | 16 | 20 |
|---|---|---|---|---|---|---|---|---|
| share with high nibble `0xF` | 18.9 % | 84.2 % | **96.8 %** | **98.6 %** | 67.4 % | 8.2 % | 6.1 % | 3.3 % |

| | `0xF` | other |
|---|---|---|
| median HR (valid readings) | **65 bpm** | **81 bpm** |
| median intensity | 0 | 32 |

A 20 % nocturnal heart-rate dip with no movement is sleep.

### Evidence — the low nibble still means what GB says

Heart-rate coverage is the discriminator, because a worn band measures a pulse:

| kind | n | valid HR |
|---|---|---|
| `0xF0` | 7 619 | **99.6 %** |
| `0xF9` | 504 | 98.2 % |
| `0x50` | 24 306 | 96.8 % |
| **`0xF3`** | 7 654 | **0.04 %** |
| **`0x73`** | 1 572 | **0.13 %** |

`0xF3` is 0.0 % covered at 01:00-08:00 *and* at 10:00-18:00 — it is the
not-worn/no-measurement state, in or out of a sleep context.

**Resolved rule:**
`asleep ⇔ high nibble == 0xF AND low nibble ∉ {3,6} AND steps == 0`
→ median **444 samples/day ≈ 7.4 h/night**, 99.6 % HR coverage, median sleep
HR 65 bpm.

---

## 2. Three defects this exposed

### 2.1 The sleep/wake gate over-reported by ~30 %

We used `sleep byte > 0`. That byte is not a boolean — it carries **56-62 during
sleep and 0-2 during the day**. Measured against the flag it marked **10 831
extra samples** as asleep, concentrated at 20:00-00:00 (evening stillness), 580
of them with a non-zero step count. Median 1 005 vs 774 samples/day.

This is the "sleep numbers are wrong" complaint, quantified.

### 2.2 Sessions merged into impossible nights

Counting `0xF3` as sleep let a daytime block of 60 not-worn samples per hour
chain onto the end of a real night, producing sessions of **1 878 min (31 h)**
and **1 053 min (17 h)**, and after a first partial fix, nights like
`01:02 → 15:02` at 98 % efficiency. Fixed by excluding not-worn, plus a 12 h cap
and a split at the 18:00 sleep-day boundary — a chain of ≤60 min gaps can
otherwise walk across an entire day without tripping the gap rule.

### 2.3 The deep-sleep byte carries no stage information

Mean heart rate by `ds & 0x7F` bucket over 16 228 sleep samples:

| bucket | 0-9 | 30-39 | 40-49 | 50-59 | 60-69 | 70-79 | 80-89 | 90-99 |
|---|---|---|---|---|---|---|---|---|
| mean HR | 75.4 | 66.1 | 66.6 | 66.6 | 65.9 | 67.1 | 67.6 | 65.9 |

**Flat.** Deep sleep must show a lower heart rate. No sub-state clusters early in
the night either. The `deepSleep & 0x7F > 52` cut from findings-09 was separating
noise. `remSleep` is identically 0 — no REM, confirmed again.

---

## 3. What replaced them

### 3.1 Wake scoring — Chinoy et al. 2020

*PLOS ONE* 2020;15(9):e0238464.
`TotalActivity = E₀ + 0.2(E₋₁+E₊₁) + 0.04(E₋₂+E₊₂)`, wake if `> 10`.

Chosen because it is the only algorithm in the literature validated against
polysomnography **on a Huami device's minute-level scalar** — the same vendor
lineage as this band (Huami Arc, n = 41, 1-min epochs): 90.3 % accuracy, 95.5 %
sleep sensitivity, with the threshold swept to 10 for that scalar versus 40 for
research-grade Actiwatch counts. Algorithm *and* operating point are published
for our class of input.

Cole–Kripke is implemented with its **real** published coefficients
(106/54/58/76/230/74/67, P = 0.001) — an earlier version of our file used
invented weights — but is not the default: its coefficients are defined over
ActiGraph counts, and our conversion would be a fabrication. A first attempt at
that conversion (scale 8.0) made any non-zero intensity score wake and collapsed
sleep efficiency to 48 %.

Checked for the idle sentinel Chinoy had to strip from the Huami Arc (a constant
`20`): our intensity histogram is smooth, no sentinel.

### 3.2 Deep sleep — detrended heart-rate dip

Heart rate falls during slow-wave sleep, but it also falls towards a **circadian
nadir near 04:00-05:00 regardless of stage**. Thresholding on the whole night
therefore finds the trough, not the cycles — measured: mean deep position 0.617
of the night. Subtracting a rolling ±45-minute median (about one sleep cycle)
removes the drift; sustained ≥10 min runs ≥1 bpm below that local baseline are
marked deep.

The threshold is calibrated, and the calibration is stated: heart rate is
integer-valued and the baseline is a median of integers, so the residual is
effectively quantised — every threshold from 1.25 to 2.0 collapses onto the same
operating point. There are really only two choices, and 1.0 bpm is the one that
lands in the 13-23 % healthy range.

### 3.3 Stopped fabricating heart rate

`_alignedHeartRate` reached ±5 minutes for a substitute reading — nearest-
neighbour interpolation by another name. A 5-minute dropout became five copies of
one value, and a repeated value has near-zero local variance, which is *exactly*
the signature the deep-sleep rule keys on. A sensor dropout could manufacture a
deep-sleep block. Capped at 3 minutes; beyond that the minute is left unstaged.

---

## 4. Before → after, same 53 days

| | before | after |
|---|---|---|
| deep share (median) | 5.7 % (range 0-41 %) | **13.4 %** (norm 13-23 %) |
| nights reporting ~0 % deep | several | **0/13** |
| nights longer than 12 h | 3 (max 14.3 h) | **0** (max 9.6 h) |
| sleep efficiency (median) | up to 98 % | 67 %, max 83 % |
| REM reported | never | never |
| typical night span | — | 476 min (7.9 h) |

Produced by `tool/analyze_capture.dart`, which runs the **shipping** analyzer
over a real capture and checks it against published norms. Unit tests prove
internal consistency; this proves physiological plausibility.

---

## 5. Still failing, and not hidden

**Deep sleep is not front-loaded.** Mean position 0.556 of the night; slow-wave
sleep should dominate the early cycles. Detrending improved it from 0.617 but did
not fix it.

Three possible explanations, undistinguished:
1. the method still is not isolating slow-wave sleep;
2. this sleeper genuinely lacks strong front-loading — the data shows fragmented
   nights (17-38 wake episodes, efficiency 54-84 %);
3. per-minute wrist heart rate simply lacks the resolution to localise SWS.
   Consumer wearables agree with PSG only 50-65 % on multi-state staging, and
   deep is among the weakest classes.

Without polysomnography, tuning further would be fitting to a prior rather than
measuring anything. The check stays in the harness and reports FAIL.

---

## 6. Verified on hardware this session

- `2021 SIGN-KEY AUTHENTICATION SUCCESS` — auth path intact after all changes
- MTU negotiated **247**; ANS `0x2A46` discovered for call alerts
- connection supervisor backoff observed live: retry #1 at 0.8 s, #2 at 1.8 s
- every band configuration command accepted, including `FE 06 00 01` (all-day
  stress) and `14 01` (1-minute HR interval)
- realtime-streaming intent survives a force-stop + relaunch
  (`HR: streaming stays off (user had it disabled)`)
- **found on hardware:** the streaming intent was not persisted, so any restart
  silently resumed the 1 Hz stream — which at 28 % battery would have flattened
  the band in ~3 h and lost the night

## 7. Still queued

- **P2.3** minute-by-minute comparison against Zepp Life for the same night —
  still the only real accuracy check. `com.urbandroid.sleep` (Sleep as Android)
  is also installed on this phone and is a second independent reference.
- Gate 8 (notification delivery) was **not** run tonight on purpose: it buzzes
  the band and the user was asleep.

---

## 8. On-screen audit (2026-08-10, 02:45-02:50, live app)

Screenshots of the running app on the device, each number checked against an
independent calculation from the pulled data. Dark mode also confirmed working
(part of **P7.1**).

### Factually correct — no change needed

| Screen | Shown | Independent check |
|---|---|---|
| Today / Heart | Resting HR **60 bpm** | Standard method (lowest sustained 30-min sleep mean) gives **60.7**; ours 60.0. Within 1 bpm. |
| Heart | "-- BPM now", "no reading" | Correct: realtime streaming was deliberately off for the night. Honest, not a blank. |
| Heart | Today's HR trace | Pulled data: 702 readings, **53-101 bpm**, zero above 150. Sane. |
| Activity | **30 steps**, 9 970 to go | Band counter read `30 steps, 20 m, 2 kcal`. Exact. |
| Activity | "683 fewer steps than yesterday" | Aug 9 per-minute total = 713. 713 − 30 = 683. Exact. |
| Activity | "No long sitting stretches", longest 12 m 00:00-00:11 | Correct — sedentary excludes sleep, and the user was awake only ~1 h of the day so far. |
| Sleep | 5 h 3 m asleep, Deep 24 m (8 %), Light 4 h 39 m (92 %) | Analyzer output for the same night: total 303 m, deep 24 m, eff 83 %. Exact, and the stages sum to the total. |

### Defects found on screen and fixed

1. **The score contradicted itself.** The breakdown showed "Deep sleep **80 %**"
   while the Insights list immediately below said "Deep sleep below the healthy
   range" — both from the same 8 % deep share. `band()` subtracted a flat 4
   points per percentage point outside the healthy range, which is not
   proportional to a metric that only spans ~0-30 %: a night with **zero** deep
   sleep still scored 48/100. Now proportional (0 % → 0, healthy floor → 100).
   **On device: 80 % → 62 %**, and the bar turned amber, agreeing with the
   insight.

2. **A 5 h 3 m night was rated "Great"** on the same card that said "Slept
   2 h 57 m under your 8 h goal". The NSF consensus (Hirshkowitz et al.,
   *Sleep Health* 2015) recommends 7-9 h for adults and classes under 6 h as not
   recommended, so the headline is now capped at "Fair" below 6 h.
   **On device: score 71 "Great" → 66 "Fair".**

3. **"Restless night" fired below 90 % efficiency**, labelling an ordinary night
   restless. 85 % is the classic normal cutoff; moved.

### Investigated and dismissed

I read the heart chart's y-axis as topping out at 189 and inferred a 181 bpm
artifact during sleep. The data disproves it — today's readings are 53-101 with
none above 150. It was a misread label, not a defect. No despiking change made,
because there is no evidence of spiking in 60 578 readings.
