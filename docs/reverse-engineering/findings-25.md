# findings-25 — deep sleep returns, as an estimate with a model behind it

*2026-09-23. Capture: 85 961 activity samples, 125 229 heart-rate readings,
2026-06-18 → 2026-09-23; 53 nights with ≥3 h of sleep after de-duplication.*

## Summary

Deep-sleep staging is **enabled again**, as a labelled estimate.
`SleepAnalyzer.kDeepStagingEnabled = true`.

findings-24 withdrew it because the detector's output was uniform across the
night — it was not finding slow-wave sleep, whatever its totals looked like.
The user asked for it back. It could only come back with a detector whose
output is front-loaded *because of how it works*, not because the constants
happened to land that way. That is what changed.

On the same capture the new rule reports a median **14.2 %** deep share
(healthy adult 13-23 %), a mean bout position of **0.446** of the night (the
harness requires < 0.45), and **1 of 53** nights with no deep at all. The old
rule, on the same nights, sat at 0.524.

*Same night, findings-26 changed session detection (sparse-flag nights are
now recovered), which changed the population: **56 nights, 20.2 % median
share, position 0.434, 0 empty nights.** The constants were not retuned; the
extra nights and the earlier, more accurate onsets moved the figures.*

## What was wrong with the old detector, precisely

It compared each minute's heart rate to a rolling median centred on that
minute, over ±45 minutes — about one sleep cycle. A median centred on the data
puts roughly half of all points below it wherever you look. The residual was
therefore negative about half the time in every part of the night, and a
threshold on it picked minutes uniformly. Widening the window did not help
(see the sweep): at ±120-180 minutes the window is clipped at session start and
dominated by the following two hours, which are *lower* as heart rate settles,
so the residual in the first hour comes out positive and the cycle-1 troughs
— where slow-wave sleep is most concentrated — are never seen.

## The replacement

Three changes, each with a reason from the literature rather than from the
sweep:

1. **Detrend with a straight line fitted over the whole session**, not a
   rolling median. Heart rate drifts monotonically towards a circadian nadir
   around 04:00-05:00 regardless of stage; a line removes that and has no edge.
   The cycle-scale troughs survive intact.

2. **Require a deeper dip the later it is.** Borbély's two-process model
   (*Hum Neurobiol* 1982;1(3):195-204) has slow-wave propensity — Process S —
   decaying exponentially from sleep onset. Slow-wave activity roughly halves
   from one NREM cycle to the next. So the dip a minute must show to qualify
   is `deepDipBpm / max(exp(-t/τ), floor)`, with τ = 240 min and floor = 0.25:
   the base dip at onset, 2.7× at 4 h, and never more than 4×. The published
   PPG stagers include a time-since-onset feature for the same reason
   (Walch et al., *Sleep* 2019;42(12):zsz180). **This is what makes the
   estimate front-loaded by construction.**

3. **Require stillness.** A minute with recorded movement above the rest
   ceiling is not a candidate, whatever its heart rate did. On this capture
   this made no measurable difference — intensity is already ≤ 12 during
   nearly all sleep — but the constraint is physiologically right and cheap.

Sustained-run and smoothing rules are unchanged (≥ 10 min, ±2-min median).

## The sweep

`tool/sweep_deep.dart` runs `detectSessions` over the capture for each
parameter set and reports median share, mean bout position, and the fraction
of nights with no deep. Nights under 3 h and naps are excluded.

Rolling-median baselines, all widths (findings-24 detector shape):

| baseline | dip | τ | floor | median share | position | empty nights |
|---|---|---|---|---|---|---|
| ±45 (old) | 1.0 | — | — | 10.0 % | 0.524 | 2/23 |
| ±120 | 1.0 | 180 | 0.50 | 9.3 % | **0.535** | 13 % |
| ±120 | 1.0 | 240 | 0.35 | 8.9 % | 0.498 | 11 % |
| ±120 | 1.0 | 240 | 0.25 | 6.6 % | 0.447 | 15 % |

Every rolling-median row that reaches a plausible share loses the
front-loading, and every row that keeps the front-loading loses the share.
That trade-off is the edge bias described above.

Linear baseline:

| dip | τ | floor | run | median share | position | empty nights |
|---|---|---|---|---|---|---|
| **1.0** | **240** | **0.25** | **10** | **14.2 %** | **0.446** | **2 %** |
| 1.0 | 180 | 0.25 | 8 | 13.5 % | 0.440 | 2 % |
| 2.0 | 360 | 0.25 | 8 | 10.1 % | 0.449 | 6 % |
| 1.5 | 240 | 0.25 | 10 | 7.9 % | 0.431 | 8 % |
| 3.0 | 360 | 0.25 | 8 | 2.7 % | 0.392 | 42 % |

The first row ships. The second is equivalent; 10-minute runs were kept
because AASM epochs are 30 s and a real bout spans tens of them.

## What this is and is not

It is a **rule-based estimate from heart rate and movement**, shaped by a
published model of sleep regulation, checked on 53 real nights for the two
properties slow-wave sleep must have: a minority share and an early
concentration. It has **not** been checked against polysomnography, and it
cannot be on this project. Consumer wearables agree with PSG only 50-65 % of
the time on multi-state staging, and deep is among the weakest classes; the
app does not claim to do better.

So every surface that shows it says "est.": the stage chip, the score
component, the insight text, the "how this is measured" note. The score
weight is 20 %, below both measured components (duration 50 %, efficiency
30 %). And `tool/analyze_capture.dart` fails the build if the output ever
stops being front-loaded — the same check that caught the old detector.

## Effect on history

Sleep scores changed for every night, twice in a month: down when deep was
withdrawn (findings-24), and now partly back up. Median score across the 53
nights moved 71 → 68 with deep re-included at a lower weight. The Sleep screen
says so.

## Left open

- **P12.3** — the band now reports its own FELL_ASLEEP / WOKE_UP events on
  `0x0010` (protocol §12), recorded to `band_events.json`. If they line up
  with detected sessions over a week they should become the anchors.
- Whether the linear detrend is still right on a night with a long mid-night
  awakening (a second "onset" would restart Process S). Not addressed; noted.
