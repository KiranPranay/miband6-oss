# findings-14 — Today screen trust pass (dashboard → health command center)

Date: 2026-06-28. Branch: `sleep-audio` (UI composition only).

Completes the four-screen trust pass ([findings-11](findings-11.md) Sleep,
[findings-12](findings-12.md) Heart, [findings-13](findings-13.md) Activity). Today
becomes a daily health **briefing** that COMPOSES the three existing engines —
not a fourth place that re-parses sensors — and it's where the review pushed
hardest for the two fabrications this project refuses (Recovery, hydration).

**No BLE / auth / protocol / parser changes.** No new metric logic — Today calls
`SleepAnalysis` / `HeartAnalysis` / `ActivityAnalysis` and combines them.

## Precondition — step over-count fully propagated

Re-grepped for raw `Σ steps` not routed through `stepsPerMinute()` (the
findings-13 fix). Findings:
- `today_tab` used `ble.metrics.steps` (the band's own counter — correct, not a
  raw sum); it now reads `activity.todaySteps` (engine-corrected) for full
  consistency with the Activity tab.
- One genuine straggler: the Gate-6 **hardware-test diagnostic** summed
  `sample.steps` directly → routed through `stepsPerMinute()`.
- All chart/aggregate paths already go through the fixed store. Today shows the
  corrected totals (which equal the band's counter), never the ~4.3× inflated sum.

## What was built

### Engine — `lib/core/daily_summary.dart`
Pure `DailySummary.compute({sleep?, heart, activity, now, spo2})` producing the
Today view-model:
- **Composite Health Score** — re-normalised weighted sum of the components that
  have data: Sleep 0.40 (real score), Activity 0.35 (real score), Heart 0.25
  (status-derived; **no displayed number**). Missing inputs are dropped and named
  (`basis` / `missing`), never invented; nothing available → null (no fake 0).
  Full weighting + the heart status→value map in [../health-score.md](../health-score.md).
- **Briefing lines** — "You slept 11h 5m", "9,929 steps to your goal", "Resting
  HR 64 · …"; sleep "vs average" only under the gate.
- **Aggregated insights** — the three engines' insights (+ a synthesized SpO2
  line), attention-first, capped to 4, tagged by domain for color.
- **Salience-ordered summary cards** — dynamic priority by discrete status BANDS
  so the order doesn't jitter (Sleep Poor 90…Excellent 20; Activity behind 80…
  goalMet 25; Heart elevated 85 / low 78 / normal 30; SpO2 <90 95…≥95 20). Works
  pre-baseline (population bands).
- **Gated trend chips** per card (sleep vs avg, activity vs yesterday, heart vs
  last week) — null until each engine's baseline gate passes.

### UI — `lib/ui/tabs/today_tab.dart`
Composite Health Score hero (breakdown always shown: Sleep 87, Activity 16,
Heart "— Normal · resting 64") → briefing card → aggregated insights → salience-
ordered summary cards that **deep-link into the detail tabs** (HomeShell passes an
`onNavigate` callback) → gated-trends note → Goals cluster (Steps + Sleep, true
unclamped %) → informative band-status block (connection · battery · last sync).

## Honesty ledger — the homepage traps
| Asked for | Decision |
|---|---|
| **Recovery score** (review asked 5×) | **OMITTED** — all such scores are HRV-based; the band has no HRV. The composite Health Score from real sub-scores is the honest replacement; resting-HR trend stays on the Heart screen. |
| **Hydration gauge** | **OMITTED** — no sensor, no data. |
| Composite score | **Shown with breakdown**; Heart contributes a status, never a number; missing inputs named, not invented. |
| Steps on Today | corrected per-minute total (= band counter), never the inflated raw sum |
| vs-yesterday / vs-average / streak trends | **Gated** on the shared Baseline |
| Distance / calories | dropped from Today (live on the Activity detail) — summary + navigation, not duplication |
| Goal cluster | Steps + Sleep only (real goals); percentages never clamped |

## Salience rule (dynamic priority)
A card's importance is its status band, not a continuous value — a notably bad
night, an abnormal HR, or a missing night rises to the top; an in-range "all good"
sinks. Discrete bands keep the order stable (no jitter on tiny deltas). Ties keep
the base order (sleep, activity, heart, spo2). Documented in code + tested.

## Hardware verification (Pixel, 1080×2424)
- Composite hero: **Today 65/100 · Fair**, breakdown Sleep 87 / Activity 16 /
  Heart "— Normal · resting 64" — math exact (87·.4 + 16·.35 + 100·.25 = 65).
- Missing-input path covered by tests (no sleep → "Based on Activity + Heart").
- Briefing + attention-first insights render; summary cards deep-link (tapped
  Activity → Activity tab); dynamic order put Activity above in-range cards.
- Goals: Steps 1% / **Sleep 139%** (unclamped, bar caps); gated-trends note 3/7;
  band-status block. No `E/flutter` / overflow across the screen.
- `flutter analyze` clean (new/changed files); `flutter test` green incl. 8 new
  `daily_summary_test` honesty cases (composite==weighted sum, Heart has no
  number, missing inputs, salience order, no Recovery/Hydration).

## Files
- New: `lib/core/daily_summary.dart`, `test/daily_summary_test.dart`,
  `docs/health-score.md`, this file.
- Changed: `lib/ui/tabs/today_tab.dart` (rewrite), `lib/ui/home_shell.dart`
  (onNavigate), `lib/core/hardware_test_session.dart` (diagnostic step total).
