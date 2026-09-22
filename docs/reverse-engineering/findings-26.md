# findings-26 — a night the band did not flag is still a night

*2026-09-23. Capture: 85 961 activity samples, 125 229 heart-rate readings,
2026-06-18 → 2026-09-23.*

## Summary

Session detection no longer depends on the band's sleep flag alone. A minute
can anchor a session either because the band flagged it (`0xF` high nibble,
findings-21) **or** because Chinoy's actigraphy scorer says the wearer was
still *and* that minute's own heart rate sits below the wearer's waking
median. Two structural guards keep the second path honest: a block opens only
on ten consecutive anchored minutes, and any block longer than 12 h is split
at its longest internal wake gap.

## The night that was missing

`tool/analyze_capture.dart`, overnight wear diagnostic:

```
2026-09-20  recorded= 960m  notWorn=  0%  hrCoverage= 97%  bandSleepFlag= 20%  -> reported 0m
```

The band was on the wrist for the entire 20:00-12:00 window with a valid pulse
on 97 % of minutes, and it flagged 20 % of them as sleep. `_isAsleepSample`
required the flag, so no block ever formed, and the Sleep screen — having no
night to show — fell back to a 21-minute evening nap and scored it against an
8-hour goal.

The flag is the band's own determination and, when present, a strong signal
(findings-21: 65 bpm median under the flag against 81 without). Its *absence*
is not evidence of wakefulness. This firmware is simply inconsistent about
setting it: across the last week the overnight flag share ran 42 / 41 / 39 /
31 / **20** / 37 / **11** %.

## What was tried, in order

**1. Actigraphy as an anchor, gated at session level.** A block could form
from still, step-free, worn minutes (Chinoy), and the whole block was then
accepted if its heart-rate coverage was ≥ 50 % and its median pulse ≥ 8 %
below the waking median.

Result: 09-20 recovered — and ten nights came out over 12 hours, the longest
840 minutes. An evening lying still on the sofa stitched onto the night
because the block's *median* was dragged down by the real sleep inside it.
This is the findings-21 failure mode, back through a different door.

**2. Corroborate each minute instead.** An unflagged still minute anchors only
if its *own* heart rate is below the gate. A still minute at waking pulse is
awake, wherever it falls.

Result: four nights over 12 h (from ten), efficiency back at 72 %, but 09-20
still ran 21:10 → 10:39 — a corroborated doze at 21:10 opened a block that
hour-long wake gaps then carried to morning.

**3. Sustained onset.** A block may only *open* on ten consecutive anchored
minutes — the first run of continuous sleep, per the actigraphy convention.
Single corroborated minutes still extend an open block.

Result: no change to 09-20 — the 21:10 doze *was* a sustained run.

**4. Split over-long blocks at the longest wake gap.** Anything over 12 h (the
99th percentile of adult time-in-bed is below that) is cut at its largest
internal gap, repeatedly, until every piece fits.

Result:

```
  PASS  no impossible nights — 0 night(s) longer than 12 h; longest 712m
```

## Inside a session

The same per-minute rule applies to staging. A minute inside a session is
awake if the wearer stepped or moved; an unflagged still minute is asleep only
with heart-rate corroboration, and stays awake without it. Two existing tests
pinned this: a fixture with no heart rate expects unflagged still minutes to
count as awake, and sleep latency to be measured from rest onset. Dropping the
flag requirement outright broke both; corroborating per minute passes both.

## Before and after, same capture

| | before | after |
|---|---|---|
| nights detected | 53 | 56 |
| median efficiency | 71 % | 70 % |
| median span | 436 min | 496 min |
| nights > 12 h | 0 | 0 |
| 09-20 | **0 min** | 330 min |
| deep share (est.) | 14.2 % | 20.2 % |
| deep position | 0.446 | 0.434 |

Deep moved because onsets moved earlier and three nights were added; the
detector's constants are unchanged.

## What this user's numbers say about the gate

The waking median across the capture is 82 bpm, so the corroboration gate is
75. On 2026-09-21 the *night's* median was 75 — right at the gate — and only
77 minutes were still-and-below-gate. For this wearer the nocturnal dip is
shallow (~9 %), so the actigraphy path fires rarely and the flag still does
most of the work. That is the intended asymmetry: the second path exists for
nights the band forgets, not to replace it.

## Open

- **P12.3** — the band now reports FELL_ASLEEP / WOKE_UP on `0x0010`
  (protocol §12). If those line up with these sessions over a week, they
  become the anchors and most of this file becomes a fallback.
- The 8 % gate is a single constant chosen from one wearer's dip. A second
  capture from someone with a deeper nocturnal dip would be the first thing to
  check it against.
