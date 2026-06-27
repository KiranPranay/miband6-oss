# findings-11 — Sleep screen: trust, gated personalization, AI "coming soon"

**Date:** 2026-06-27
**Branch:** `sleep-audio` (UI). No BLE/auth/parser changes.

Acted on the external design review in risk tiers, with the governing rule:
never present a computed health value as a measurement without a real basis, and
never build a personal baseline from contaminated/thin history.

## Tier 1 — built (presentation over data we already have correctly)
- **Score breakdown** (the #1 trust fix): refactored the score into named
  weighted `ScoreComponent`s (Duration 0.55 / Deep 0.30 / Efficiency 0.15 — the
  real formula) and render "What makes up this score" so e.g. 87 next to low deep
  is explained, not mistrusted. Doc: `docs/sleep-score.md`.
- **Explain alarming numbers:** Consistency now shows its cause ("bedtimes varied
  by Xh Ym").
- **Metric context:** honest *population*-normal qualifiers ("74 bpm · Normal",
  SpO2/efficiency tiers).
- **Colour hierarchy:** score = one identity colour (indigo), rating word =
  semantic tint, goal bar = distinct blue — green no longer dominates.
- **Microcopy:** "You slept 2h44m longer than yesterday".
- **Dedup/log/timeline:** trimmed Sleep-log entry height ~20%; added a scannable
  stage-% header above the hypnogram ("Deep 13m (2%) · Light 10h43m (97%) · …").

## Tier 2 — gated personalization (`docs/sleep-baseline.md`)
Personal baselines use ONLY post-parser-fix nights (cutoff 2026-06-26) and only
once there are ≥ 7. Until then: population "In/Below/Above **range**" status (not
"average"), the per-stage "vs your avg" line hidden, the weekly card in a
"building" state, and a "Building your baseline · N of 7 nights" note. Verified on
device both gated-off (3/7 → ranges + note) and gated-on (temporarily lowered the
gate → "−25m vs your avg", real weekly averages, sleep debt), then restored.

## Tier 3 — computed metrics
- **Sleep debt: BUILT (gated).** Σ max(0, goal − night) over the post-fix
  baseline window; shown in the weekly card with a tap-through explaining the math.
- **Recovery score: OMITTED** — needs HRV, which the band lacks; a number would be
  invented. **Circadian / trend forecast: DEFERRED** with specs. All captured in
  `docs/deferred-sleep-metrics.md`.

## AI Analysis — deliberate "coming soon"
The review's wanted one-line AI summary IS the deferred AI feature. Added a
polished, clearly-labelled "AI Analysis · SOON" card on the Sleep screen (taps to
the existing coming-soon screen) — **not** a templated sentence pretending to be
AI. Rule-based one-liners remain in the Insights section, labelled as insights.

## Verification
`flutter analyze` clean; `flutter test` green incl. new `sleep_analysis_test.dart`
(score = Σ component·weight; gate off < 7 nights → no debt/avg; gate on ≥ 7 →
debt = Σ shortfall). On Pixel: HR/SpO2/sleep still display correctly (no
regression to the data paths).
