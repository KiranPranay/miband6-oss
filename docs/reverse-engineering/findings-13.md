# findings-13 — Activity screen trust pass (step counter → activity coach)

Date: 2026-06-28. Branch: `sleep-audio` (UI + data-aggregation only).

Companion to [findings-11](findings-11.md) (Sleep) and [findings-12](findings-12.md)
(Heart). Same discipline: **build the real, gate the derivable, omit the fake.** Turns
the Activity screen from a passive step counter into a coach that answers "am I moving
enough?".

**No BLE / auth / protocol / parser changes.** The one data-layer change is an
aggregation-correctness fix in `ActivityStore` (not the byte parser) — see §1.

## The data discovery that drove everything (§1)

The on-device `activity_data.json` (pulled via `run-as`) revealed two things the class
docs got wrong, both verified by hand-decoding real bytes:

1. **Samples are sub-minute, ~every 20 s — not one per minute.** A single day held
   **7,546** samples (~5/min), all with unique timestamps (not duplicates).
2. **Within each minute, every sub-sample repeats the SAME step count.** e.g. the 18:43
   minute had 15 samples all reading `98` steps. So `Σ sample.steps` over-counts by the
   samples-per-minute factor (~4–6×): a real **4,538**-step day summed to **19,592**, and
   the hourly chart silently disagreed with the hero.

**Fix:** `stepsPerMinute()` collapses each minute to one representative value (max), and
`ActivityStore.totalStepsForDate` / `getStepsByHour` now route through it. Verified: the
collapsed daily total equals the band's own step counter **exactly (4,538)**, and weekly
totals became sane (e.g. 22,479 for a week, not ~90k).

3. **The `intensity` byte is unreliable for movement classification.** Median per-minute
   intensity is ~40 *even while sitting* (it captures any wrist motion). Gating
   "active/high-intensity" on intensity produced a bogus "728 minutes of high-intensity
   movement". **Steps are the reliable locomotion signal**, so active/brisk/sedentary are
   step-cadence based; intensity is deliberately **not** used to gate them.

## What was built

### Engine — `lib/core/activity_analysis.dart`
Pure `ActivityAnalysis.compute({liveSteps, todaySamples, hourly, allSamples, now, dailyGoal})`
mirroring Heart/Sleep. Per-minute granularity throughout. Produces:
- **Status / pace** — true (unclamped) daily %, "expected by now" projection over a 7–22 h
  waking window, status pill (Behind / On track / Ahead / Goal reached). Too-early →
  "just getting started", no projection from noise.
- **Active minutes** (≥20 steps/min) and **brisk minutes** (≥60 steps/min) — labelled
  estimates, never named sports.
- **Longest inactive stretch** — longest run of zero-step *waking* minutes, gap-aware
  (an un-synced gap >2 min ends the run; we never count unobserved minutes as sitting),
  sleep excluded via `!isSleep` (sleepStage, never the deep/rem bytes).
- **Peak / least-active hour** (least among waking hours only).
- **Weekly / monthly** true %s; descriptive "highest day".
- **Gated** (shared `Baseline`): daily average, vs-yesterday, vs-last-week, best day, and a
  **goal streak** — counted back from *yesterday* (today is partial); a day with no synced
  data **breaks** the streak (skipping it would invent continuity).
- **Activity Score** — see [activity-score.md](../activity-score.md): a number *because*
  it decomposes into shown, weighted, real components.

### UI — `lib/ui/tabs/activity_tab.dart`
Active hero (status pill + true %/to-go + honest pace), insights, sedentary card,
movement-pattern line above the hourly chart, reordered metric grid (Distance, Active,
Brisk, Calories, **Activity HR** [avg during walking minutes, "--" when none], Steps),
Day/Week/Month toggle (Month only when data spans it), gated weekly summary + building
note, decomposable score card, recommendations.

## Honesty ledger
| Item | Treatment |
|---|---|
| Today steps / distance / calories | **Real**, today-only (no historical distance/calories source — never faked) |
| Active / brisk minutes | **Real**, step-cadence estimates (intensity rejected as noisy) |
| Longest inactive stretch, peak/least hour | **Real**, waking-only, gap-aware |
| Daily/weekly/monthly % | **Real**, never clamped (bar caps; number doesn't) |
| vs yesterday / last week, streak, daily avg, best day | **Gated** (post-fix + ≥7 days) |
| Activity Score | **Shown with components** (auditable) — see activity-score.md |
| **Floors / elevation** | **Omitted** — no altimeter; test asserts absence |
| Named sport types (running/cycling) | **Omitted** — a wrist counter can't tell them apart |

## Hardware verification (Pixel, 1080×2424)
- Step over-count fix: corrected today total = band counter (4,538); week 22,479 (32%);
  no inflated bars anywhere.
- Today: status pill + pace projection correct (incl. late-night "behind"), sedentary
  stretch with time range, movement line, building-baseline note 3/7.
- Metric grid: Activity HR shows "--" with no data, real bpm (102) when present.
- Week: 7-bar chart + "Highest day" line + gated building summary.
- Month: 30-bar adaptive chart ("Highest day: Thursday · 10,287"), no gated card.
- Activity score 17/100 with the three components summing correctly; recommendations.
- `flutter analyze` clean (new/changed files); `flutter test` green (incl. new
  activity_analysis_test honesty cases). No `E/flutter` / overflow across all views.

## Files
- New: `lib/core/activity_analysis.dart`, `test/activity_analysis_test.dart`,
  `docs/activity-score.md`, this file.
- Changed: `lib/ui/tabs/activity_tab.dart` (rewrite), `lib/core/activity_sample.dart`
  (`stepsPerMinute`), `lib/storage/activity_store.dart` (corrected aggregation).
