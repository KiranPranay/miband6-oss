# Deferred / omitted sleep metrics

The design review asked for several "premium" metrics. Each is a **health claim**,
so none ships as a bare number without a documented, auditable basis. Status:

## ✅ Sleep debt — BUILT (gated)
Accumulated shortfall vs the user's goal over recent post-fix nights:
`Σ max(0, goal − night_total)` over the baseline pool. Real and auditable —
shown in the weekly card with a tap-through explaining the math, and gated on the
same ≥7 post-fix-night baseline as the rest of personalization
(docs/sleep-baseline.md). Never negative; framed as "catch up gradually", not a
debt you can repay in one night.

## ❌ Recovery score — OMITTED (do not fake)
Real recovery scores (Oura/Whoop) are built on **HRV** plus resting-HR trends.
This band exposes **no HRV**. A "Recovery 92" with no such basis is an invented
measurement — exactly what this project forbids. **Not built.**
- *If revisited:* only as an honestly-labelled "resting-HR trend" once enough
  post-fix nights of resting-HR exist — never branded "recovery", and never a
  single opaque 0–100 number implying physiological recovery.

## ⏸ Circadian rhythm / optimal bedtime — DEFERRED (spec only)
A recommended bedtime is something users will *act on*, so a guessed time is
harmful. A defensible version needs ≥2–3 weeks of post-fix bedtime/wake +
sleep-quality data to find the bedtime that correlates with the best nights.
- *Spec:* from ≥14 post-fix nights, regress sleep score / deep% against bedtime,
  suggest the bedtime window of the top-quartile nights, labelled "based on your
  last N nights" with the supporting data shown. Until that data + validation
  exist, show nothing.

## ⏸ Trend forecast ("at this pace, weekly avg 9h12m") — DEFERRED
Only acceptable as a simple, clearly-labelled projection from real post-fix data
(e.g. linear fit over the baseline window), marked "estimate". Low value until the
baseline gate is met and several weeks of data exist; deferred to avoid a
confident line drawn through 3 noisy points.
- *Spec:* once ≥14 post-fix nights, a 7-day moving-average trend line with a
  dotted "projected" segment, explicitly labelled an estimate.

## Principle
Every item above either has an auditable formula (sleep debt) or is withheld until
it does. No HRV → no recovery score. Thin/contaminated history → no baseline,
forecast, or circadian recommendation. This mirrors the SpO2/sleep-parser
discipline: never present a computed health value as a measurement without a real
basis.
