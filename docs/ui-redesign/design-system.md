# UI Redesign — Design System

The presentation layer (`lib/ui/`) was rebuilt as a light, professional-but-lively,
multi-tab experience. This document is the source of truth for the design tokens,
typography, motion rules and reusable widgets that every screen is built from.

> **Hard boundary:** the redesign touches **only** `lib/ui/` + `lib/main.dart`
> (theme + root scaffold swap). It does **not** change `lib/core/*` or
> `lib/storage/*` — the hardware-verified BLE / auth / activity / notification
> layers are untouched. Screens read live data through the existing
> `BLEManager` / `ActivityStore` providers.

## Principles

- **Light-first.** Soft off-white canvas (`#F4F6FB`), white surfaces, deep-ink text.
  No pure black, no pure white background.
- **One token source.** Colors, spacing, radii, shadows, motion and type all come
  from `lib/ui/theme/tokens.dart` + `lib/ui/theme/app_theme.dart`. No screen
  hardcodes a hex value, a `TextStyle`, or a raw duration.
- **Domain color = meaning.** Each health domain has a fixed accent (heart = coral,
  activity = green, sleep = indigo, SpO₂ = teal, calories = orange, distance = blue)
  used consistently across tabs, icons, charts and rings.
- **Lively, not loud.** Motion is quick and purposeful (count-ups, a pulsing HR ring,
  animated progress, collapsing headers). Every decorative animation is gated behind
  the OS *reduce-motion* setting.

## Color tokens (`AppColors`)

| Token | Hex | Use |
|---|---|---|
| `scaffold` | `#F4F6FB` | app background |
| `surface` | `#FFFFFF` | cards |
| `surfaceAlt` | `#EDF0F7` | track / inset fills, segmented control bg |
| `divider` | `#E7EAF1` | hairlines, chart gridlines |
| `primary` / `primarySoft` | `#5468FF` / `#E9ECFF` | brand, primary actions |
| `heart` / `heartSoft` | `#FF5A72` / `#FFE4E9` | heart rate |
| `activity` / `activitySoft` | `#1FB877` / `#DBF6EB` | steps / movement |
| `sleep` / `sleepSoft` | `#6366F1` / `#E7E8FE` | sleep |
| `spo2` / `spo2Soft` | `#14B8A6` / `#D4F4F0` | blood oxygen |
| `calories` / `caloriesSoft` | `#FB8C3C` / `#FFEAD7` | calories |
| `distance` / `distanceSoft` | `#3B82F6` / `#DDEAFE` | distance |
| `sleepDeep/Light/Rem/Awake` | `#4338CA` / `#8B93F8` / `#22C9E0` / `#F6B23E` | hypnogram stages |
| `ink` / `inkMuted` / `inkFaint` | `#161B2E` / `#707892` / `#A3AAC0` | text hierarchy |
| `success` / `warning` / `danger` | `#1FB877` / `#F59E0B` / `#EF4444` | states |

Tints are applied with `color.withValues(alpha: …)` (never the deprecated
`withOpacity`). Icon chips use a `0.14` alpha tint of their domain color.

## Spacing, radii, shadows

- **`AppSpacing`** — `xs 4 · sm 8 · md 12 · lg 16 · xl 20 · xxl 24 · xxxl 32`.
  Horizontal page padding is always `lg` (16).
- **`AppRadii`** — `sm 12 · md 16 · lg 20 · xl 28 · pill 999`. Cards use `lg`,
  the floating nav uses `xl`, pills/buttons use `pill`.
- **`AppShadows.card`** — a soft two-layer ambient shadow used by every surface.
  `AppShadows.glow(color)` adds a colored halo for active/primary elements
  (e.g. the live "Measure" button, the HR ring).

## Typography (`AppText`, Manrope via google_fonts)

| Style | Size / weight | Use |
|---|---|---|
| `metricHero` | 52 / w800 | the big number inside the HR ring |
| `metric` | 30 / w800 | large hero numbers |
| `metricSm` | 22 / w800 | stat-card values |
| `h1` | 24 / w800 | screen titles / section heads |
| `title` | 16 / w700 | card titles |
| `body` | 14 / w500 | body copy |
| `label` | 13 / w600 | quiet labels (inkMuted) |
| `caption` | 11.5 / w600 | captions / nav labels (inkFaint) |
| `unit` | 13 / w700 | unit suffix beside a metric |

## Motion (`AppMotion`)

- Durations: `fast 180ms · medium 280ms · slow 440ms`.
- Curves: `ease` = `easeOutCubic`; `emphasized` = `Cubic(0.2, 0, 0, 1)`.
- **Reduce-motion:** `AppMotion.reduced(context)` reads
  `MediaQuery.disableAnimations`. When true, `CountUpText` jumps straight to its
  value, the HR ring stops pulsing, the gradient orb and progress rings render
  static. No information is ever conveyed by motion alone.

## Reusable widgets (`lib/ui/widgets/`)

| Widget | Purpose |
|---|---|
| `AppCard` | base white surface — rounded, soft shadow, optional `onTap` ripple |
| `CountUpText` | animates a number up to its value on appear/change (reduce-motion aware) |
| `StatCard` | tinted icon chip + animated value + unit + label tile |
| `SectionHeader` / `Pill` | section title row (+ trailing control); rounded status pill |
| `PulsingHeartRing` | circular HR display; inner glow pulses at `60000/bpm` ms; calm "measuring…" state; reduce-motion → static |
| `SegmentedToggle` | pill segmented control (e.g. Today / Week) with an animated thumb |
| `ChartCard` / `ChartEmpty` | titled frame around an fl_chart body; friendly empty state |
| `ComingSoonScreen` | animated gradient-orb "coming soon" preview (Stress, AI Analysis) |

## Charts (fl_chart ^0.69)

House style: transparent background, horizontal-only gridlines in `divider`,
top/right axis titles hidden, tiny `caption`-styled bottom/left labels, curved
line charts with a domain-color gradient area fill, rounded bar rods, and touch
tooltips with an `ink` background + white text (`getTooltipColor` in 0.69).
Empty data renders `ChartEmpty` inside the `ChartCard` rather than a broken axis.

## Navigation shell (`home_shell.dart`)

A `Scaffold(extendBody: true)` with an `IndexedStack` (keeps each tab's scroll +
animation state alive) behind a **floating pill bottom-nav**: five rounded
destinations (Today / Heart / Activity / Sleep / Profile), the selected one
lifted into a tinted pill in its domain color. Content scrolls *under* the nav;
every tab ends with a 96px bottom spacer so nothing hides behind it.

See [screens.md](screens.md) for the per-screen breakdown.
