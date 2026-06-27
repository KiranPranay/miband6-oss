# Activity Score — why it exists (unlike a Heart Score)

**Decision:** the Activity screen *does* show a 0–100 Activity Score, because — unlike
a cardiac score — it decomposes into real, named, measured, weighted components that
are shown to the user. The score is never a black box.

See the sibling decision for why the Heart screen has **no** score
([heart-score.md](heart-score.md)): a cardiac score would need HRV/validation the band
can't provide. Activity is different — its inputs (steps vs goal, walking minutes,
sitting time) are real and meaningful, so a transparent composite is defensible.

## The components (shown on the card)

`ActivityAnalysis` computes the score as a weighted sum of three sub-scores, each
rendered with its own bar + detail line so the user can audit it:

| Component | Weight | Sub-score (0–100) | Why |
|---|---:|---|---|
| **Steps vs goal** | 0.50 | `min(steps / dailyGoal, 1) × 100` | The headline behaviour; capped at 100 so the *bar* doesn't overweight a huge day (the hero still shows the true unclamped %). |
| **Active minutes** | 0.30 | `min(activeMin / 30, 1) × 100` | Rewards sustained movement, not just a high one-off step count. Target 30 active min/day. |
| **Movement breaks** | 0.20 | `(1 − longestSit / 120) × 100`, floored at 0 | Penalises long uninterrupted sitting; ≥2 h continuous → 0. The most behaviour-changing signal. |

`activityScore = round(Σ sub-score × weight)`, in `[0, 100]`. A unit test asserts the
score equals the weighted sum of its shown components, so the card can never drift from
the number.

## Honesty constraints baked in

- **Computed only when there is real per-minute data today** (`waking.isNotEmpty || todaySteps > 0`); otherwise `activityScore` is null and the card is hidden — no "0/100" for an un-synced day.
- **Step counts are corrected** for the band's per-minute duplication before scoring (see [findings-13](reverse-engineering/findings-13.md)); a raw-sample score would be ~4× too high.
- **Active/brisk minutes are step-cadence based** (≥20 / ≥60 steps per minute), not the band's noisy `intensity` byte. Labelled estimates, never METs.
- **No floors / elevation component** — the Mi Band 6 has no altimeter; a test asserts no floors/elevation/climb component can appear.
- It is a **single-day** score (no history pollution); weekly/monthly trends are shown separately and gated on the shared [Baseline](sleep-baseline.md).

## When to revisit the weights

The weights are a defensible default, not a validated model. If real usage shows the
movement-breaks term dominating on low-step days (it can), consider rescaling — but keep
the rule: **every term stays a real, shown, measured quantity.** Don't add a term we
can't display and audit.
