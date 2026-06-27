# Personal sleep baseline — gating

The Sleep screen prefers "your normal" over generic "healthy range" — but a
personal baseline is only trustworthy if it's built from clean data and enough of
it. Two hard gates (in `lib/core/sleep_analysis.dart`):

## 1. Post-parser-fix nights only
The sleep-stage parser was wrong until findings-09; historical nights decode to
unreliable distributions. Baselines therefore **exclude** any night before the
fix:

```dart
static final DateTime _baselineCutoff = DateTime(2026, 6, 26); // parser fix / clean-capture start
final postFix = nights.where((d) => !d.date.isBefore(_baselineCutoff));
```

(Using a date is the simplest reliable flag here since sleep is recomputed from
raw samples rather than stored per-night; a schema-version flag on stored sleep
records would be the alternative if sleep were persisted.)

## 2. Minimum sample
No "your average / your normal range / vs your baseline" language appears until
there are **≥ 7** post-fix nights:

```dart
static const int _minBaselineNights = 7;
final hasBaseline = postFix.length >= _minBaselineNights;
```

`hasPersonalBaseline`, `baselineNightCount`, `baselineNightsNeeded` are exposed
for the UI.

## What's gated on `hasPersonalBaseline`
- Per-stage "± vs your avg" (hidden until ready; the population **range** status —
  "In/Below/Above range" — is always shown since it's not personal).
- Weekly **Average**, **Consistency** (+ its "bedtimes varied by …" cause),
  **Best/Lowest night** — the whole weekly-summary card shows a "building" state
  until ready.
- Stage averages / `deltaVsAvg` are computed only from `basePool` (last ≤7
  post-fix nights).

## Until the gate is met
- Stage cards compare to the **population healthy range**, not a personal average.
- A "Building your baseline · N of 7 nights" note (with a progress bar) explains
  why personalization isn't on yet — so its absence reads as deliberate, not
  broken.

## Once met
- Stage cards show "± vs your avg"; the weekly summary shows real personal
  averages; metric qualifiers can move from population-normal to personal framing
  in a later pass.

This is the same discipline that fixed SpO2/sleep: never compute a confident
personal number from contaminated or thin history.
