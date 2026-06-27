# Heart screen — why there is no "Heart Score" number

**Decision:** the Heart screen presents heart health as **trend + status**, not as a
single 0–100 "Heart Score". This document records why, so the choice isn't quietly
reversed later.

## The rule

The project's hard rule is: *never present a computed value as a measurement unless
it has a real, auditable basis.* A score is allowed **only** if it decomposes into
real, named components the user can audit — the way the [Sleep score](sleep-score.md)
breaks into Duration / Deep / Efficiency, each a measured quantity with a published
weight.

## Why a Heart Score fails that test (today)

A "cardiac health score" from this band would have to be built out of the few signals
we actually have:

- **Resting heart rate** — real, and we show it prominently.
- **Current / min / avg / max BPM** — real, shown on the chart and summary.
- **HR-vs-activity context** — real (each sample carries `heartRate` + `intensity` +
  `steps`), shown on the highest-reading card.

What we **do not** have is the data a defensible cardiovascular score needs:

- **No HRV** (heart-rate variability). The Mi Band 6 doesn't expose it over this
  protocol. HRV is the single most important input to recovery/readiness/stress
  scoring; without it any "score" is mostly resting-HR re-skinned.
- **No VO₂max, no calibrated cardio-fitness model**, no demographic baseline beyond
  the user's own short history.
- **No clinical validation.** Collapsing BPM into a 0–100 number invents a precision
  and a medical authority we can't stand behind. Two people with identical BPM traces
  can have very different cardiac health; a number hides that, a status doesn't.

So a Heart Score would be a **decorative composite** — exactly the "computed value
presented as a measurement" the rule forbids. It would also be the most prominent
thing on the screen, which makes the dishonesty worse, not smaller.

## What we show instead

A trend/status framing that maps 1:1 to real data:

| UI element | Backing data | Honest because |
|---|---|---|
| Status pill (Low / Normal / Elevated) | current BPM vs population bands | it's a band membership, not a graded score |
| Resting HR + label ("Healthy resting HR") | calmest 10 % of last-7-day readings | a real measured statistic with a plain-language band |
| Trend chip (Rising / Stable / Easing) | recent readings vs the rest of the window | describes movement, claims no absolute grade |
| Insights | rule-based checks on the above, each labelled | each line is auditable from one rule |
| Zone bands + min/avg/max markers | the actual readings | descriptive, not scored |

## Deferred / omitted (same discipline)

- **Stress → "coming soon."** Needs HRV. We surface it as a clearly-labelled preview
  (`ComingSoonScreen`), never a number computed from BPM.
- **Recovery → omitted.** Needs HRV; shown on the "More heart metrics" card with the
  reason ("Needs HRV — not on Mi Band 6") rather than hidden or faked.

## When to revisit

Add a Heart Score **only if** a future device/firmware gives us HRV (or another
validated input) *and* the score decomposes into named, measured, weighted components
shown to the user — the Sleep-score bar. Until then, trend + status is the honest
ceiling. See also [deferred-sleep-metrics.md](deferred-sleep-metrics.md) for the same
reasoning applied to sleep.
