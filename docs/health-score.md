# Today's Health Score — composite, and what it deliberately is NOT

The Today homepage leads with a single **Health Score** that answers "how am I doing
today?". It is a transparent composite of the three things the band can honestly
measure — **never** a Recovery or Readiness score, and **never** a Hydration gauge.

## Why no Recovery / Hydration (the homepage traps)

The product review asked for a "Recovery 84" hero five times, citing Oura/Whoop/Garmin.
**All of those are HRV-based.** The Mi Band 6 does not stream heart-rate variability, so
a recovery/readiness number here would be a fabricated measurement — the exact thing this
project refuses, made worse by putting it on the homepage. **Omitted.** The only honest
recovery-adjacent signal is the resting-HR trend, which already lives on the Heart screen
labelled as exactly that.

**Hydration** has no sensor and no data. A "Hydration 60%" gauge would be pure fiction.
**Omitted.** (Manual water logging is a possible *future* feature — a real input, not a
fake gauge — and is out of scope.)

## What the score is made of

`DailySummary.compute()` composes the existing, already-honest engines — it does not
re-parse or re-aggregate raw sensor data:

| Component | Source | Contribution | Shown as |
|---|---|---:|---|
| **Sleep** | `SleepAnalysis.score` (0–100) | 0.40 | the real number + rating ("Excellent") |
| **Activity** | `ActivityAnalysis.activityScore` (0–100) | 0.35 | the real number + status ("Behind goal") |
| **Heart** | `HeartAnalysis` **status** | 0.25 | a **status**, never a number |

`healthScore = round( Σ value·weight / Σ weight )` over the components that have data.

### Heart has no number — by design

Heart deliberately has **no** 0–100 score ([heart-score.md](heart-score.md)) because a
cardiac score can't be made auditable without HRV. So Heart contributes to the composite
via a **documented mapping from its real status**, and the breakdown shows that *status*
("Normal · resting 59"), never a fabricated "Heart 84":

| Heart state | composite value |
|---|---:|
| Current status **elevated** | 70 |
| Current status **low** | 82 |
| Resting HR ≤ 70 ("healthy") | 100 |
| Resting HR 71–100 ("within normal") | 85 |
| Resting HR > 100 ("higher than typical") | 65 |
| Resting HR < 40 ("unusually low") | 80 |
| Normal, resting not yet established | 90 |

This mapping is a coarse, non-diagnostic health proxy — published here so it isn't a black
box. It is the *only* place a heart figure influences a number, and it is never displayed.

## Missing inputs are handled honestly

Weights are **re-normalised over the components that actually have data** — a missing piece
is never silently invented:

- No sleep recorded last night → the score is built from Activity + Heart, and the UI says
  **"Based on Activity + Heart"** (the `basis` / `missing` lists drive this).
- No per-minute activity yet → Activity is excluded (its score is null until real data).
- No HR at all → Heart is excluded.
- **Nothing available → `healthScore` is null** and the hero shows a "wear your band"
  prompt, not a fake `0`.

## Auditability

The breakdown is always shown inline (Sleep number, Activity number, Heart status), exactly
like the Sleep and Activity score breakdowns — the headline number can never drift from its
parts (a unit test asserts `healthScore == Σ value·weight / Σ weight`). All "vs average"
phrasing in the briefing remains gated on the shared [Baseline](sleep-baseline.md).
