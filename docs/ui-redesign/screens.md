# UI Redesign — Screens

Five primary destinations behind a floating pill bottom-nav, plus two
"coming soon" shells and the restyled secondary screens. All screens read live
data from the existing `BLEManager` / `ActivityStore` providers — the redesign
did not change any `lib/core` or `lib/storage` code. See
[design-system.md](design-system.md) for the shared tokens/widgets.

## Navigation shell — `lib/ui/home_shell.dart`

`IndexedStack` of the five tabs (state preserved across switches) under a custom
floating pill nav. The active destination lifts into a tinted pill in its domain
color. `extendBody: true` lets content scroll under the nav; each tab ends in a
96px spacer.

---

## 1. Today — `lib/ui/tabs/today_tab.dart`

The hero dashboard. `RefreshIndicator` → one-shot HR measurement on pull.

- **Collapsing header:** greeting (by local hour) + full date on the left, a
  connection `Pill` (Connected/Disconnected) and battery `Pill` on the right.
- **Heart-rate card:** `PulsingHeartRing` showing live BPM (pulses at the live
  rate), with a Measure/Stop button toggling realtime HR.
- **Stats grid (2×2):** Steps, Distance (km), Calories, SpO₂ — animated
  `StatCard`s. Laid out with `Row`/`Expanded` (no manual width math).
- **Steps goal:** animated progress bar toward 10,000 steps + percent.
- **Last-synced** footer (relative time).

## 2. Heart — `lib/ui/tabs/heart_tab.dart`

- Header "Heart" + live "N BPM now".
- Hero `PulsingHeartRing` + Start/Stop realtime button.
- Today / Week `SegmentedToggle`.
- **`fl_chart` line chart** of `hrReadings` (curved, coral gradient fill, touch
  tooltips), filtered to today or the last 7 days. `ChartEmpty` when no history.
- Min / Avg / Max tiles and a Resting-HR card (avg of the lowest 10%).

## 3. Activity — `lib/ui/tabs/activity_tab.dart`

- Header "Activity".
- **Steps hero ring** (custom `CustomPaint` progress ring) toward the daily goal;
  Today shows the live count, Week the 7-day total.
- Today / Week `SegmentedToggle`.
- **`fl_chart` bar chart** — hourly bars for Today, 7-day totals for Week;
  graceful empty state ("No steps recorded today").
- Supporting `StatCard` grid: Distance, Calories, Active minutes, Avg HR.

## 4. Sleep — `lib/ui/tabs/sleep_tab.dart`

- Header "Sleep" + the night's relative date ("Last night").
- **Hero:** total sleep duration + a quality pill (Great/Fair/Poor).
- **Hypnogram:** a hand-built `Row` of flex segments per interval, colored by
  stage (deep/light/REM/awake) + a legend.
- **Stage breakdown:** Deep / Light / REM / Awake cards with minutes + percent.
- **Last-7-nights** `fl_chart` bar chart.
- Friendly empty state when there's no sleep data.

> **Known data-layer caveat:** the "time asleep" total is whatever
> `ActivityStore.computeSleepDays()` returns. That method groups sleep intervals
> with a 4-hour-gap rule (`lib/storage/activity_store.dart`); with some bands'
> data the intervals lump into one oversized group, so the total can read far
> higher than a single night. This is **frozen data-layer logic** the UI
> redesign intentionally did not touch — the screen renders the API faithfully.
> Fixing the night-grouping belongs in a separate data-layer change.

## 5. Profile — `lib/ui/tabs/profile_tab.dart`

- Avatar header "Your Band" / device model.
- **Device card:** name, connection state, battery bar, last sync, and a
  Connect/Disconnect action.
- **Features list:** Notifications, Stress (coming soon), AI Analysis (coming
  soon), Settings, Debug Console — each pushes its screen.
- About card (version + one-line description).

---

## Coming-soon shells

`Stress` and `AI Analysis` are reached from Profile and use the shared
`ComingSoonScreen` (animated gradient orb + "COMING SOON" badge + description).
No fake data, no dead controls — a deliberate, on-brand placeholder.

## Restyled secondary screens

- **Settings** (`settings_screen.dart`) and **Notifications**
  (`notifications_screen.dart`) were re-skinned from the old dark theme to the
  light theme — behavior, handlers and navigation unchanged, only visual tokens
  swapped (and deprecated `withOpacity` / `activeColor` cleared).
- **Auth key**, **Device scan** and **Debug console** are theme-neutral and
  inherit the light theme directly (the debug console keeps its terminal look).

First-run setup is reachable via **Profile → Settings → Scan & Connect / Auth
Key**, so nothing is stranded.

---

## On-device verification (Pixel 9a, Android 17)

Built and run on hardware with the real Mi Band 6:

- Connect → **2021 sign-key auth success** → activity fetch (≈240 samples, ≈160
  derived HR readings, SpO₂) → **live HR streaming** (verified in logcat,
  e.g. `HR notify … -> 72 bpm`), all behind the new UI — no regression in the
  core BLE/auth/data pipeline.
- All five tabs navigate and render; charts populate from real history.
- **Zero** framework exceptions across repeated tab switches spanning the
  data-arrival relayout.

### Fixes made during verification

1. **Layout crash** (`_elements.contains` cascade): the Today/Activity stat grids
   computed `SizedBox(width: (maxWidth - gap)/2)`, which went **negative** under a
   transient ~0-width layout pass → "BoxConstraints has a negative minimum width"
   → cascading element/layout assertions → red error screen. Replaced the manual
   width math with `Row`/`Expanded` (flex clamps internally). Crash-proof.
2. **Header title doubling:** Today/Heart/Sleep rendered the title twice (once in
   `FlexibleSpaceBar.title:` and again in the `background:`, which overlapped).
   Consolidated each header into the `background` only.
