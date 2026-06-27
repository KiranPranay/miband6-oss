# Sleep score formula

The Sleep screen's 0–100 score is a **weighted sum of named sub-scores**, surfaced
in the hero ("What makes up this score") so the number is auditable — e.g. a high
score next to low deep sleep is explained, not mistrusted.

Defined in `lib/core/sleep_analysis.dart` (`SleepAnalysis.compute` →
`scoreComponents`). Each component is a 0–100 sub-score with a fixed weight; the
weights sum to 1.0; `score = round(Σ sub·weight)`.

| Component | Weight | Sub-score (0–100) | Source |
|---|---|---|---|
| **Duration** | 0.55 | `clamp(total / goal, 0..1) · 100` | night total vs the 8 h goal |
| **Deep sleep** | 0.30 | `band(deep%, 13–23)` | deep-sleep share vs the healthy band |
| **Efficiency** | 0.15 | `efficiency%` | time asleep ÷ time in bed |

`band(pct, low, high)` returns 100 inside the healthy range and falls off 4 points
per percentage-point outside it (clamped 0–100).

Rating: ≥85 Excellent · ≥70 Great · ≥55 Fair · else Poor.

## Why these three (and not REM / consistency)
- **REM is excluded** — MB6 does not measure it (findings-09); scoring it would be
  fabricated.
- **Consistency is *not* in the score** (yet). It needs multi-night history, and
  most historical nights pre-date the parser fix (findings-09), so averaging them
  would contaminate the result. Consistency is shown separately in the weekly
  summary with its cause ("bedtimes varied by …"), and personal-baseline framing
  is gated on ≥7 post-fix nights (see docs/sleep-baseline.md). All three score
  components above are **single-night**, so the score is never polluted by old
  garbage.

## Honesty note
Efficiency reads ~100% on MB6 because the session span ≈ time asleep (the band
gives no distinct "in bed but awake" signal). It is shown for transparency but
contributes little discrimination; the score is effectively driven by Duration
and Deep. The breakdown makes that visible rather than hiding it.
