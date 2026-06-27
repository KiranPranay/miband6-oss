# findings-12 — Heart screen trust pass (sensor dashboard → heart-health view)

Date: 2026-06-27. Branch: `sleep-audio` (UI only).

Companion to [findings-11](findings-11.md) (the Sleep trust pass). Same discipline,
applied to the Heart screen: **never present a computed value as a measurement unless
it has a real, auditable basis.** Build the real, gate the derivable, omit the fake.

**No BLE / auth / protocol / parser changes.** HR data itself was already correct
(HR byte verified in findings-07). This pass is entirely presentation + a pure
analysis engine over data we already capture.

## What was wrong (the gap vs Sleep)

The Heart screen was a bare sensor dashboard: a big live-BPM ring, a Today/Week chart,
and min/avg/max. It led with an instantaneous number, buried resting HR, gave no
status/trend context, no insights, and no honest position on stress/recovery. Compared
to the post-fix Sleep screen it under-used real data **and** risked implying health
meaning it hadn't earned.

## What we built

### Engine — `lib/core/heart_analysis.dart`
Pure `HeartAnalysis.compute({currentBpm, hrReadings, samples})` → a value object the UI
renders (mirrors `SleepAnalysis`). Everything below is derived from real captured data:

- **currentStatus** — population band (Low <50 / Normal ≤100 / Elevated) of the live BPM.
- **restingHr + label** — calmest 10 % of the last-7-day readings; plain-language band
  ("Healthy resting HR", etc.).
- **trend** — most-recent fifth of the window vs the rest (±3 bpm = stable); `unknown`
  until ≥10 samples, never guessed.
- **today min/avg/max** and **highest event** with **real activity correlation**: the
  activity sample nearest the peak (within 2 min) decides `duringActivity`
  (`steps>0 || intensity≥20`). The card says "141 bpm · 9:55 AM · during activity" —
  honest "during activity", *never* an invented exercise type.
- **insights** — rule-based, labelled (resting-in-range, spike-while-inactive,
  vs-last-week [gated], steadiness).
- **gated weekly stats** (avg/resting/high/low + signed vs-last-week) behind the shared
  `Baseline` gate.

### Shared gate — `lib/core/baseline.dart`
Extracted the Sleep personalization gate (post-fix cutoff `2026-06-26` + `minSamples 7`)
into `Baseline`, and pointed **both** `SleepAnalysis` and `HeartAnalysis` at it, so
"your average / vs last week / personal normal" only appear once enough clean,
post-parser-fix days exist. (For HR the gate is the minimum-sample guarantee + UI
consistency, not because old HR values were wrong.)

### UI — `lib/ui/tabs/heart_tab.dart`
- **Hero** leads with Current BPM + status pill + a "● LIVE" recording state and a
  trend chip; **resting HR gets first-class prominence** with its honest label.
- **Insights** card (green check / amber info), mirroring Sleep.
- **Chart** tints the population HR zones it touches (Resting/Normal/Elevated) and draws
  dashed min/avg/max markers, with a labelled zone legend.
- **Highest-reading** card with the real activity context above.
- **Day/Week/Month** toggle — Month appears only when readings actually span beyond a
  week. Week adds a "This week" summary card: gated stats once the baseline is met,
  otherwise a "Building your baseline · N of 7 days" progress note. Month shows
  descriptive min/avg/max only (engine's gated stats are 7-day).
- **Recommendations** card — generic-safe, "not medical advice".
- **More heart metrics** card — Stress = "Coming soon" preview (never computed from
  BPM); Recovery = omitted with the reason ("Needs HRV — not on Mi Band 6").
- Colour roles via tokens: pink = live, purple = resting/trends, green = healthy,
  amber = warnings.

### Decision — no "Heart Score"
Deliberately trend/status framing, not a 0–100 number. A cardiac score can't decompose
into auditable measured components on this band (no HRV / VO₂max / validated model), so
it would be a decorative composite presented as a measurement. Full rationale +
revisit-criteria in [`../heart-score.md`](../heart-score.md).

## Honesty ledger (what's real / gated / omitted)
| Item | Treatment |
|---|---|
| Current / min / avg / max / resting HR | **Real**, shown |
| HR-vs-activity ("during activity") | **Real** (concurrent sample), shown |
| Status / trend / insights | **Real**, rule-based, labelled |
| Weekly avg / resting / high / low, vs last week | **Gated** (post-fix + ≥7 days) |
| Month view aggregates | descriptive min/avg/max only (not personal) |
| Heart Score | **Omitted** — trend/status instead (docs/heart-score.md) |
| Stress | **"Coming soon"** — needs HRV; never from BPM |
| Recovery | **Omitted** — needs HRV the MB6 lacks; reason shown |

## Hardware verification (Pixel, 1080×2424)
- Hero: live HR streamed into the hero (78→88 bpm), status "Normal", trend "Rising",
  resting 63 "Healthy resting HR", "● LIVE" while monitoring.
- Today: chart with zone bands + min/avg/max markers; summary 55/77–78/141; **highest
  141 bpm · 9:55 AM correctly flagged "during activity"** from concurrent samples.
- Month: 30-day chart with date axis, descriptive 49/84/141, no gated card (correct).
- Week: "Building your baseline · 2 of 7 days" with progress bar and the honest note —
  **no fabricated weekly averages or vs-last-week** (only 2 post-cutoff days exist).
- Recommendations + Stress(coming-soon)/Recovery(omitted) cards render.
- No `E/flutter` / `RenderFlex` / overflow exceptions across all views; no SpO2/sleep
  regression. `flutter analyze` clean for the new/changed files; `flutter test` green.

## Files
- New: `lib/core/heart_analysis.dart`, `lib/core/baseline.dart`, `docs/heart-score.md`,
  this file.
- Changed: `lib/ui/tabs/heart_tab.dart` (rewrite), `lib/core/sleep_analysis.dart`
  (use shared `Baseline`).
