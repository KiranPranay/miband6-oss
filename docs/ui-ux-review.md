# UI/UX review — principles, where they are applied, and what is still open

**Date:** 2026-08-09
**Scope:** every screen in `lib/ui/`. This documents *decisions*, not aspirations
— each principle below names the concrete place it is implemented, and the
"Still open" section is deliberately explicit about what has **not** been done.

Related: `docs/ui-redesign/design-system.md`, `docs/ui-redesign/screens.md`,
and the per-screen trust passes in `findings-11` (Sleep), `findings-12` (Heart),
`findings-13` (Activity), `findings-14` (Today).

---

## 0. The rule that overrides the others: don't lie

Every other principle here is subordinate to this one. A wearable app is
trusted with health numbers, and a number that *looks* authoritative but was
invented is worse than a blank.

Applied as:

| Rule | Where |
|---|---|
| A value is either measured, derived-and-labelled, or absent | Stress screen shows a "Measured by band" / "Estimated by app" chip next to the number |
| No metric without a sensor | No Hydration; no Floors (no altimeter); no Recovery (needs HRV, which this firmware does not send) |
| No REM sleep | The firmware never populates the REM byte — Gate 7 *fails* the session if REM is ever reported |
| Personal comparisons are gated | Streaks/comparisons stay hidden until a real baseline exists, and say how many days remain |
| Percentages are not clamped | An over-100 % efficiency signals a bug; hiding it would hide the bug |
| Unsupported settings are absent, not greyed out | SpO2 all-day and sleep-breathing quality are ZeppOS-only, so the Band settings screen omits them — a disabled switch implies "nearly there" |

## 1. Visual hierarchy & progressive disclosure

- **Today** leads with a composite Health Score and a briefing, then salience-
  ordered summary cards that deep-link into the detail tabs
  (`today_tab.dart`, findings-14). Detail is one tap away, never on the surface.
- **Debug tooling is off the main path**: the console, hardware test session and
  test-notification trigger live under Settings → Developer. The console is not
  reachable from any primary screen.
- Verbose packet logging is **off by default** (`BLELogger.verbose`), so the
  debug surface does not leak into normal use even when opened.

## 2. Hick's law — fewer choices per screen

- Band settings are grouped into **Measurement / Display / Goals & reminders**
  (`band_settings_screen.dart`) rather than one flat list of ~15 switches.
- Multi-option settings use a bottom sheet showing only that setting's choices,
  instead of inline pickers competing for attention.
- Ranges offer only what the data supports: "Month" appears on Heart/Activity
  **only** when readings actually span beyond a week.

## 3. Fitts's law — reach and safety

- Primary actions (measure HR, refresh, tab bar) sit in the lower/thumb region.
- `materialTapTargetSize: MaterialTapTargetSize.padded` app-wide plus
  `listTileTheme.minVerticalPadding` keeps rows at the ≥48 dp target.
- **Destructive actions are distant and confirmed**: Disconnect is at the bottom
  of Settings → Device, styled in the danger colour, and clears the saved device
  + connection intent deliberately rather than as a side effect.

## 4. Goal-gradient & streaks — motivating, never shaming

- Steps/sleep progress rings and a goal cluster on Today.
- Streaks appear **only** once a real baseline exists (findings-13), so the app
  cannot invent a streak from two days of data.
- Missed goals are framed neutrally — the copy states the number and moves on.
  There is no "you failed", no red X, no guilt language anywhere in the insight
  or briefing generators.

## 5. Peak–end rule — the morning sleep summary

The sleep summary is the emotional peak of a tracker, so it gets a calm,
one-glance card: stage timeline, efficiency, and one actionable insight
(`sleep_tab.dart`, findings-11). The rebuilt analyzer (findings-18) is what makes
it *true* as well as pretty — a beautiful card showing 98 % light sleep was the
previous state, and that is worse than an ugly correct one.

## 6. Aesthetic–usability & calm tech

- 8-pt spacing scale (`AppSpacing`), one radius scale (`AppRadii`).
- **One accent per metric domain**, hue-stable across themes:
  heart = warm pink, sleep = indigo, activity = green, SpO2 = teal,
  **stress = deeper teal**, calories = orange, distance = blue.
  A test asserts the hues stay within 25° across light/dark so a metric remains
  identifiable by colour after a theme switch.
- Material 3 throughout; motion tokens are short and purposeful (`AppMotion`),
  and `AppMotion.reduced(context)` reads `MediaQuery.disableAnimations` so
  decorative animation can be gated by the OS reduced-motion setting.

## 7. Light **and** dark

Implemented this pass. The token layer was `static const` colours baked for
light only; it is now an `AppPalette` with `light`/`dark` instances and
`AppColors` getters that resolve against the active one. `MiBandApp` observes
`platformBrightness` and repoints the palette, so a system theme change applies
immediately without a restart.

Dark is **not** an inversion:
- surfaces are near-black (`#0E1017`/`#171A23`), not pure black — pure black
  kills the elevation shadows and is harsher at night, which is when this app
  is actually read;
- accents are lifted in lightness but keep their hue;
- "soft" tints become dark low-saturation fills rather than pale washes;
- card shadows are scaled up, because a black shadow on a near-black surface
  does nothing — separation comes mainly from surface-vs-scaffold contrast.

## 8. Perceived performance

- Cached last-known metrics are shown immediately; `_metrics` is deliberately
  **not** cleared on disconnect so the screen never blanks.
- Connection state is a single explicit `ConnectionPhase` with human labels
  ("Connecting…", "Reconnecting…") — never a raw exception.
- Settings toggles are **optimistic with rollback**: they move at once and flip
  back with an explanation if the band refuses (`BandConfigController.update`).
- The heavy work is off the frame path entirely — analyses memoised against the
  store revision, JSON encoding on a background isolate, and charts wrapped in
  `RepaintBoundary` inside the shared `ChartCard` (findings-15).

## 9. Feedback & trust

- Every band write logs a result, and the settings screen surfaces failures as
  a human sentence rather than an exception.
- The notification relay records an explicit `RelayDecision` for **every**
  dropped notification (disabled / app not selected / band not ready /
  duplicate / screen on) — previously notifications died silently in three
  different places.
- "Send a test notification" bypasses Android entirely, so a user (or a
  developer) can tell which half of the path is broken in one tap.

## 10. Accessibility

- **Contrast is now enforced by a test**, not by eye:
  `test/theme_contrast_test.dart` computes WCAG 2.1 ratios for both palettes and
  fails the build below 4.5:1 (text) / 3:1 (non-text).
- That test found **real defects in the existing light palette** and they were
  fixed rather than the thresholds lowered:

  | Token | Was | Ratio | Now | Ratio |
  |---|---|---|---|---|
  | `inkMuted` | `#707892` | 4.38 | `#6E7691` | 4.50 |
  | `inkFaint` | `#A3AAC0` | 2.32 | `#8C94B0` | 3.01 |
  | `activity` / `success` | `#1FB877` | 2.57 | `#1DA96E` | 3.02 |
  | `spo2` | `#14B8A6` | 2.49 | `#12A796` | 3.00 |
  | `calories` | `#FB8C3C` | 2.35 | `#F66A05` | 3.01 |
  | `warning` | `#F59E0B` | 2.15 | `#CE8508` | 3.01 |
  | `sleepRem` | `#22C9E0` | 2.00 | `#1CB3C8` | 2.52 |
  | `sleepAwake` | `#F6B23E` | 1.85 | `#E2920B` | 2.51 |

- Touch targets ≥48 dp via the theme (§3).
- Dynamic type: text styles are relative and the layouts are scroll-based, so
  larger system font sizes do not clip. **Not yet verified at the largest
  accessibility sizes** — see below.

---

## Still open (honest list)

These are **not** done. They are listed here rather than quietly omitted.

1. **Semantic labels are incomplete.** Metric tiles largely read as their raw
   text ("72", "BPM") to a screen reader instead of a composed label
   ("Heart rate, 72 beats per minute"). A pass adding `Semantics` wrappers to
   the shared metric widgets is the next accessibility task.
2. **Dynamic type not tested at extreme sizes.** Needs a device pass at the
   largest OS font setting to find clipping, especially in the hero numbers.
3. **Skeleton loaders**: the app shows cached values plus a spinner in a few
   places rather than shape-matched skeletons. Cached-first already avoids the
   worst of it, so this is polish, not a gap in truthfulness.
4. **Chart decimation and pinch/scrub.** Charts currently plot the points they
   are given. A day of per-minute HR is ~1440 points; they should be decimated
   to roughly the pixel width before plotting, and support pinch/scrub. Deferred
   because it needs on-device profiling to tune (queued with P1.1).
5. **Haptic feedback on band writes** is not wired.
6. **Dark mode has not been seen on a device.** It compiles, the palette is
   contrast-tested, and the switching logic is exercised by tests — but nobody
   has looked at it. Queued as **P7.1**.

## Verification status

| Item | Status |
|---|---|
| Contrast thresholds, both palettes | ✅ automated test |
| Palette switching | ✅ automated test |
| Hue stability across themes | ✅ automated test |
| `flutter analyze` | ✅ clean |
| Visual appearance on device | ❌ **not verified — no device this session** |
| Screen-reader pass | ❌ not done (see Still open #1) |
