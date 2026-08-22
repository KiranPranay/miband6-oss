# findings-24 — the deep-sleep detector does not find deep sleep

*2026-08-22. Capture: 38 071 activity samples, 81 471 heart-rate readings,
2026-06-18 → 2026-08-17, de-duplicated (every completed day exactly 1440 min).*

## Summary

Deep-sleep staging is **quarantined**. `SleepAnalyzer.kDeepStagingVerified` is
`false`, the Deep stage is no longer presented, and the sleep score's remaining
components are re-normalised.

The detector's output is distributed **uniformly across the night**. Slow-wave
sleep is front-loaded. So whatever it is finding, it is not slow-wave sleep —
and no choice of constants changes that, only how many minutes get the label.

## How this came up

P10.2 recorded that the deep-sleep calibration had been fitted on captures
carrying 56% duplicate samples, and that after de-duplication the median deep
share read 10.0% against a healthy adult 13-23%. The task looked like a
re-calibration.

The published-norms check passes at 10.0% only because the check is a range
test with slack. The harness has a second check, and it **fails**:

```
FAIL  slow-wave sleep is front-loaded — mean deep position 0.524 of the night
      (should be well below 0.5)
```

## The sweep

Every combination of the three constants, over the same capture:

| min run | baseline half-window | median deep | mean position | nights ~0% |
|---|---|---|---|---|
| 10 | 45 (current) | 10.0% | 0.524 | 2/23 |
| 8 | 45 | 15.5% | 0.501 | 0/23 |
| 10 | 60 | 11.8% | 0.507 | 1/23 |
| 10 | 90 | 15.6% | 0.520 | 0/23 |
| 10 | 120 | 16.7% | 0.533 | 0/23 |
| 8 | 90 | 19.1% | 0.526 | 0/23 |
| 12 | 90 | 8.8% | 0.515 | 3/23 |

The dip threshold was swept separately (1.0 → 3.0 bpm); 1.0 is already the most
permissive useful value, because the residual is effectively integer-valued.

**The share moves from 5% to 19%. The position does not move at all.**

Several of those rows land inside the published 13-23% band. Picking one would
have made every plausibility check pass. It would have been the same minutes,
in the same wrong places, relabelled until the total looked healthy.

## Why the position cannot move

`_refineWithHeartRate` marks a minute deep when smoothed heart rate sits
`deepDipBpm` below a **rolling median of itself**. A rolling median is centred
on its own data, so about half of all residuals are negative by construction,
and they are spread evenly across the series.

Measured directly on three nights — minutes at residual ≤ −1.0 bpm, counted
into night-thirds:

```
night 08-10:  1531 min,  635 qualifying   →  219 / 205 / 211    mean pos 0.495
night 08-13:   460 min,  198 qualifying   →   60 /  74 /  64    mean pos 0.507
night 08-16:   518 min,  228 qualifying   →   71 /  77 /  80    mean pos 0.515
```

Uniform. The detrending step, added to remove the circadian downward drift, also
removes the very structure that distinguishes early-night slow-wave sleep from
a quiet moment at 5 a.m.

Both earlier attempts failed the same test from the other side. Thresholding on
the whole night's distribution put the mean position at **0.617** — it found the
circadian nadir. Detrending puts it at **0.524** — it finds nothing in
particular.

## What was changed

- `SleepAnalyzer.kDeepStagingVerified = false`; `_refineWithHeartRate` is not
  called. Every measured minute is staged `light`, i.e. *asleep*.
- The Deep stage is dropped from `SleepAnalysis.stages`, from insights, and
  from recommendations.
- Deep carried **30%** of the sleep score. It is removed and Duration/Efficiency
  are re-normalised (0.79 / 0.21). Dropping the component rather than scoring it
  zero matters: a zero reads as "you got no deep sleep", which is a claim about
  the user.
- The code and its tests are kept, skipped on the flag, as the specification a
  replacement must meet.

## What would lift the quarantine

A detector whose output is front-loaded on these captures.
`tool/analyze_capture.dart` already checks it — the bar is the existing
`slow-wave sleep is front-loaded` assertion, not a share that lands in range.

Worth being honest about the ceiling: Chinoy et al. (PLOS ONE 2020;15(9):e0238464)
validated Huami devices for sleep/wake, not staging, and consumer wearables agree
with polysomnography only about 50-65% of the time on multi-state staging, with
deep and REM the weakest classes. One-minute optical heart rate with no RR
intervals may simply not carry the signal. If so, the honest end state is the
current one.

## Related

- P10.2 in `pending-hardware-verification.md` — closed by this document.
- findings-21 — the kind byte carries no depth signal either (`0xDB` has the
  *highest* mean HR of any sleep kind: sleep onset, not depth).
- findings-23 — the same shape of problem in the stress stream, resolved the
  same way.
