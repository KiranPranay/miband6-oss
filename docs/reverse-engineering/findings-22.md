# findings-22 — the UI inconsistency had one dominant cause, and it wasn't styling

Date: 2026-08-12
Device: Mi Band 6 (EC:98:4A:3C:1D:87), phone 55211XEBF1RB28, dark mode
Method: screenshots of all five tabs at both scroll extremes, before and after
each change, on the running app with live band data.

The report was "the UI is very inconsistent, the bottom bar overlaps on
scrolling, the headings are not good, the settings screen overlapped, and the
application looks so filled". Five complaints; six causes. Only one of them is
about taste.

---

## 1. A stale palette, frozen into `const` widgets

**Symptom.** Section headings on some screens rendered in a dark navy that is
almost invisible on the near-black background — "Features", "About", "Goals",
"Today's insights", "Recommendations", "More heart metrics". Other headings on
the *same screen*, in the same widget class, rendered correctly in white:
"Activity score", "This week", "Sleep log". Separately, the "More heart metrics"
card on the Heart tab was painted solid `#FFFFFF` in the middle of a dark UI.

**Cause.** `AppColors` / `AppText` are process-wide getters resolved at build
time, and Flutter's `Element.updateChild` short-circuits when a widget instance
is `identical` to the previous one — which is always true of a `const` widget.
So a `const SectionHeader('Recommendations')` built once is *never* rebuilt, and
keeps whatever palette was active during that one build, forever.

Android reports `platformBrightness == light` for the first frame or two of a
cold start, then corrects. Anything built in that window froze into light-mode
colours:

| Token | Light value | On the dark scaffold `#0E1017` |
|---|---|---|
| `ink` | `#161B2E` | near-invisible heading |
| `surface` | `#FFFFFF` | the white card |

Sections built *later* — behind an `if (data != null)` gate, or lazily by a
sliver — were built after the correction and came out right. That is why the
result looked arbitrary rather than like a single bug, and why it read as
"inconsistent styling" rather than as one defect.

**Fix.** `_PaletteGate` (main.dart) sits below `MaterialApp`, reads the
*resolved* `Theme.of(context).brightness` rather than the raw platform value,
and wraps its child in a `KeyedSubtree` keyed on that brightness. A change to
the key discards the element tree instead of updating it, so const widgets are
rebuilt from scratch.

**Test.** `test/palette_swap_test.dart`. Three of the four tests pin the fixed
behaviour; the fourth asserts that the *naive* tree really does go stale. If
Flutter ever starts rebuilding identical const widgets, that test fails and the
guard should be re-examined rather than left in place as cargo.

> Worth remembering beyond this bug: any global mutable style read at build time
> is one `const` away from going stale. The tokens are convenient precisely
> because they skip `BuildContext`, and that is exactly what breaks them.

---

## 2. Content scrolling behind the status bar

Sleep and Profile put their titles in a plain `SliverToBoxAdapter`. Nothing was
pinned at the top of the viewport, so once the header scrolled away the content
beneath ran up under the system status bar — card text rendered behind the clock
and the battery icon.

Today, Heart and Activity each hand-rolled their own `SliverAppBar`, with
different expanded heights (156 / 150 / 152) and different internal padding.
Five tabs, four header treatments.

All five now use `TabHeaderSliver`: pinned, opaque `AppColors.scaffold`
background, one geometry. Today keeps a greeting instead of a noun for its
title, which is a content decision, not a structural one.

**Trap hit while fixing this.** An `AppBar` `title:` and a `FlexibleSpaceBar`
`background:` are drawn *at the same time*, so the first attempt printed the
screen name twice — large and small — whenever the header was expanded. The
component now computes the collapse fraction from `LayoutBuilder` constraints
and cross-fades the two, handing over in the second half of the collapse so the
two are never both legible.

---

## 3. The floating nav clipped the last card on every tab

`HomeShell` uses `Scaffold.extendBody: true`, so the body extends underneath the
nav. Every tab compensated with a hardcoded `SliverToBoxAdapter(SizedBox(height:
96))`. The nav is 66 (pill) + 12 (margin) + the phone's gesture inset (~24) =
~102 before any breathing room. Short by ~30 px, on all five tabs.

`AppLayout.navClearance(context)` prefers the value Flutter has *already*
measured — under `extendBody`, `_BodyBuilder` reports the bottom bar's full
height as the body's `MediaQuery.padding.bottom` — and falls back to the
constants when there is no such Scaffold to measure.

The first attempt used `viewPadding` instead of `padding` and produced 94 px,
i.e. no visible change from the 96 it replaced. Verified on device, not
inferred. `test/nav_clearance_test.dart` pins the arithmetic against a Scaffold
shaped like the real shell.

---

## 4. Heading hierarchy

`SectionHeader` used `AppText.h1` — 24 px / w800 — which is also the screen
title style. A screen therefore had four or five equally loud titles and nothing
to read as "top level". Section headers now use `AppText.sectionTitle`
(17 px / w700), one step down.

Its padding was also inverted: 8 px above, 12 px below, which by the Gestalt law
of proximity grouped each header with the card *above* it rather than the one it
labels. It now owns a wide leading gap and a narrow trailing one, and callers no
longer add their own `SizedBox` before each header — so the rhythm cannot drift
per screen.

Settings drew its own headers entirely — 11 px uppercase indigo with 1.4
tracking — and now delegates to the shared component.

---

## 5. Density: the same fact told six times

On the Today tab, a short night was reported in the score card (Sleep 67 ·
Fair), the briefing card ("You slept 3h 34m · 1h 36m below your average"), three
of the four insight bullets, the "Your day" sleep row, and the sleep goal bar.
Six statements of one fact before the first scroll, while activity and heart got
one line between them.

- The briefing card is gone. Every line it carried already appeared elsewhere on
  the same screen — it was a card of pure restatement. `DailySummary.briefing`
  and `_BriefingCard` were deleted with it.
- `DailySummary.insights` now takes at most one item per domain, so the overview
  *covers* the day instead of dwelling on one part of it. The detail tabs still
  list everything, which is where the depth belongs.

---

## 6. Data-clarity defects found while looking at the screens

These are not layout problems. They were visible only because the screenshots
were read against the numbers.

**Heart trend chart plotted against reading index, not time.** `FlSpot(i, …)`
means equal horizontal distance = equal *number of samples*, and sampling here
is wildly uneven — one reading per second during live monitoring, one every few
minutes otherwise. On a real day the axis read `00:00 · 14:55 · 18:51 · 23:43`:
the first third of the chart covered fifteen hours, the last third covered five.
Now plotted against minutes from the first reading, with the series broken
wherever a gap exceeds the sampling interval, so a stretch with no data reads as
a gap rather than an interpolated line.

**Heart chart y-axis labels overprinted.** fl_chart emits a title at the axis
minimum *and* at each interval step; when those landed within a line-height of
each other they were drawn on top of one another — the live chart showed "52"
and "50" stacked. Labels too close to the axis edge are now dropped.

**Activity sub-scores showed weights as if they were achievement.** The row read
"Steps vs goal · 50%" next to "3,959 / 10,000" (= 40%) with the bar filled to
40%. The 50% is the component's *weight in the formula*. Three numbers, one
meaning something entirely different, unlabelled. The achieved score is now the
prominent figure and the weight says "weight 50%".

**"This week" was not a week.** The sleep summary pool is the last seven
*recorded* nights — a deliberate choice, since a personal baseline needs a
minimum number of nights rather than a calendar window (see
`docs/sleep-baseline.md`). But the section was headed "This week", and on live
data those seven nights ran **1 July – 10 August**. Average, consistency, best
and lowest night, and a 19h 50m sleep debt were all true of that pool and false
of the week.

This surfaced only because the bar chart's weekday labels were made unambiguous
first: with gaps in the history, seven nights can span more than a week, and the
axis had been reading `Wed Thu Fri Sat Sun Sun Mon` — two bars with the same
name. The axis falls back to dates whenever a weekday repeats, and that is what
exposed the July dates.

The section is now headed "Recent nights" and the card states its own span
("7 nights · 1 Jul – 10 Aug"); best/lowest night carry dates as well as
weekdays. The statistics were not changed — only the claim made about them.

**Switches were unreadable when on.** `activeThumbColor: AppColors.primary` was
set at four call sites, i.e. the thumb was given the same colour as the track,
so an enabled switch was a featureless indigo pill — *less* legible than a
disabled one, which at least showed a white thumb. Removed; the theme now gives
the selected thumb a contrasting colour. The checkbox tick had the same problem
(white on light indigo in dark mode).

---

## What was checked and found fine

- Activity's `SliverAppBar` already had an opaque background; content being
  clipped at its lower edge while scrolling is ordinary scroll-under, not a bug.
- The insight bullets' trailing coloured dots encode the domain and match the
  score-card dots. Kept.

## Still open

- Today's step count comes from summed activity samples, while the band's own
  `0x0007` counter read 5,269 at the same moment the UI showed 3,959. Two
  sources, two numbers, no reconciliation. Not a display bug — needs a decision
  about which source is authoritative. Queued in
  `pending-hardware-verification.md`.
