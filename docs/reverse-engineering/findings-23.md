# findings-23 — the stress data was never stress, and the night was never 8h41m

Date: 2026-08-12
Device: Mi Band 6 (EC:98:4A:3C:1D:87), phone 55211XEBF1RB28
Capture: 69 419 activity samples (2026-06-18 → 08-12), 68 833 HR readings,
26 863 stored stress readings, pulled off the phone with `run-as`.

Two questions were asked: why last night's time-in-bed and sleep duration
disagreed so badly, and whether the stress figures were any good. The answers
turned out to be connected only in that both were the same kind of error —
a decoder trusting a documented layout that the data does not match.

---

## 1. Last night: the 8h41m was invented, the 3h57m was real

Reported: `2026-08-12  23:23→08:04  span=521m total=237m deep=18m (7.6%)
awake=284m eff=45% lat=76m wakes=35`. Every other night in the capture sits at
52-83% efficiency.

| Metric | Was | Is | Which |
|---|---|---|---|
| Time in bed | 8h 41m (521) | **6h 29m (389)** | defect |
| Total sleep | 3h 57m (237) | **3h 56m (236)** | real |
| Efficiency | 45% | **61%** | follows TIB |
| Latency | 76 min | **18 min** | defect |
| Awakenings | 35 | **7** (≥5 min) | defect |
| Deep sleep | 18m (7.6%) | **10m (4.2%)** | real, and genuinely low |

**Mechanism.** `_isAsleepSample` accepted low nibble 9 (light) or 11 (deep)
*even when the high nibble said the band was not flagging sleep*. Exactly three
such samples — 00:03 `c=0x9b` at intensity 117 with HR 92, 07:03 and 07:19
`c=0x79` — sat inside two wake gaps of 69 and 71 minutes, both past
`maxWakeGapMinutes = 60`. They were the only thing holding the night together as
one block. Remove them and it splits correctly.

The stitched-on leading 76 minutes contains **174 steps across 9 minutes** and
an HR peak of 112 bpm; the trailing 102 minutes is a third off-wrist with no
heart rate at all. Neither is bed time, and calling the first "sleep latency" is
simply wrong.

**The comment justifying the fallback was false.** It claimed kind 9/11 "occur
only *inside* flagged sleep on this firmware (628 light / 72 deep out of
60 404)". Against this capture: **207 of 823** kind-9/11 samples (25%) carry a
non-0xF high nibble; their median HR is 73 against 65 for `0xF0`; 104 of 207
have intensity ≥ 20; 62 fall between 08:00 and 10:00. That is waking movement.
The cited counts match nothing — not this capture (721/102), not its
flagged-only subset (583/33), not findings-21 (`0xF9` = 504.)

findings-21 §9.1 had already retired kind 11 as "deep". This extends the same
verdict to kind 9, and to the *staging* path, which read depth from the same
byte. That looked harmless because `_refineWithHeartRate` resets every asleep
minute to light before deciding depth from HR — but it returns early when HR
coverage is thin, and on exactly those nights the discredited staging survived.

**The 35 awakenings were the classifier flapping.** Eighteen were exactly one
minute long, twenty were ≤2 minutes, seven were ≥5. At those eighteen minutes
the heart rate sat **1.25 bpm below** the surrounding median and only 4 of 16
rose by ≥5 bpm. A real arousal raises heart rate. The mechanism is arithmetic:
`_weightedSumAwake` scores a minute as `at(i) + 0.2·neighbours + 0.04·(±2)`
against `chinoyWakeThreshold = 10`, so a single isolated minute of intensity 11
flips to wake — roughly this night's 85th percentile of sleeping movement. The
threshold is Chinoy's validated value and was deliberately **not** retuned;
counting awakenings at ≥5 minutes is the standard actigraphy convention and
leaves WASO and efficiency untouched.

**Duplicates were not involved in this night.** 18:00→12:00 held 1 080 samples
in 1 080 distinct minutes, zero duplicates. (They are a real problem elsewhere —
see §3.)

**Verdict for the user.** A genuinely mediocre night: a short opportunity
(00:23→06:52), WASO around 105 minutes, low deep sleep. But not the catastrophe
45% implied — the app overstated it by 16 points of efficiency and invented two
and a half hours of bed time. Across all 18 nights: median efficiency
68% → 71%, median span 476 → 437 min, awakenings 17-62 → 1-8.

### The contradictory kind byte

`0xF3` means "asleep" (high nibble `0xF`) **and** "not worn" (low nibble 3) at
the same time. It is not rare: **8 438 samples, 12.2% of the capture, and 44% of
every band-flagged-asleep minute** — of which exactly **3 have a heart-rate
reading**. A band that is off the wrist cannot know you are asleep; the flag is
stale. `isNotWorn` already wins over the sleep flag, which is correct, and this
is recorded here because the ratio is the clearest single argument that the
band's own flag needs corroboration rather than trust.

---

## 2. Stress: all 26 863 stored readings were activity bytes

Not "some were wrong". Every one.

**Auto (24 390 records).** `parseStressAuto` advances one minute per byte. The
payload is an 8-byte-per-minute activity record stream, so the clock runs eight
times fast: the readings spanned 2026-08-04 → **2026-08-18**, i.e. 63% of them
were dated *after* the moment they were fetched, the newest six days ahead. A
mod-8 profile of the stored values reproduces the MB6 sample layout slot for
slot — kind / intensity / steps / HR / unknown1 / sleep / deepSleep (0 of 2 962
survive the `v > 100` filter) / remSleep (100% zero).

**Manual (2 473 records).** 2 472 of them are dated between 1970 and 2105 — a
near-uniform smear across the whole uint32 range, which is what reading
arbitrary bytes as a little-endian epoch looks like. 86.5% are exact 5-byte
windows of the real activity byte stream (controls: 3.6-35.2%). Hand-decoded:
the record `t=31744000, v=64` is the bytes `00 7c 00 00 40` — its "stress score
of 64" is literally that minute's heart-rate byte.

**What this looked like on screen.** Replayed at the real wall clock, the hero
rendered **96 / "High" / red / "Measured by your band"**, driven by a row dated
an hour in the future, with a breathing exercise suggested off the back of it.
The value changed minute to minute as the `.abs() <= 60` window slid. The "Last
7 days" card drew seven bars dated 2105-08-07 to 2105-10-08 with ordinary
weekday labels.

### What is NOT established

**Whether the band is at fault.** Two hypotheses fit the bytes equally:

1. The band ignores fetch type `0x13`/`0x12` and serves activity data.
2. Our own `0x01` transfer leaks into the stress buffer. `_completeFetch`
   resolved on a stall without sending stop, never cancelled `_dataSub`, and
   shares one `_dataBuffer` across fetch types — a client-side leak predicts the
   same alignment.

Evidence cuts both ways. One fetch round is activity-shaped over 95% of its
comparable extent; another matches only as a ~360-minute prefix and then decays;
a third matches 7.6%. For one window the activity fetch stored 120 samples while
the `0x13` payload ran 1 341 records and disagreed on the HR byte at 19:14
(0 vs 77) — which favours two genuinely distinct transfers. **Probe P1 settles
it.** `findings-20` already marked this "not hardware-verified"; this is an
unverified doc being falsified, not hardware-beats-docs.

### What shipped

- Ingest gated behind `BLEManager.kStressFetchVerified` (false). The fetch still
  runs and logs what came back — that log *is* the probe.
- `ActivityFetcher.looksLikeActivityStream` rejects an 8-byte payload before
  parsing, on the two invariants that hold across all 69 419 captured samples
  without exception: **`deepSleep` bit 7 set** and **`remSleep == 0`**. A
  threshold on `deepSleep == 0x80` was considered and rejected — it holds for
  83.5% of samples overall and 62% overnight, so it would miss precisely the
  sleep-heavy buffers.
- `parseStressManual` rejects the payload **whole** on a bad length or any
  implausible instant. Keeping the records that happen to land in range is how a
  plausible-looking lie gets stored. (Gadgetbridge does the same:
  `FetchStressManualOperation.java:65-68`.)
- `addStressReadings` drops anything dated in the future.
- `ActivityStore.purgeUnverifiedStress()` **renames** the old file to
  `stress_data.v0-unverified.json` rather than deleting it — those bytes are a
  decoded copy of real activity data and P1 may want them.

### Historical stress, on the one signal that is trustworthy

With the band's stream quarantined, history is derived from stored heart rate by
the same method the live figure already used: position each hour's mean HR
within the user's own 10th-90th percentile range **for that circadian bin**.

The circadian part is load-bearing, not a refinement — resting HR varies across
the 24-hour cycle by more than the deviation being measured (night RHR ~3.9 bpm
below day: Speed C, Arneil T, Harle R, et al., *PLOS Digital Health*
2023;2(4):e0000236), so an all-hours baseline would read "calm" at 3 a.m. and
"elevated" every afternoon purely from the clock.

Over the real capture: 441 scored hours across 23 days, and the shape is what
you would expect — night 30, morning 45, midday 43, evening 46.

Honesty rules the screen holds to: an hour without enough HR data is **absent**
from the chart, never drawn as zero; a day with fewer than six scored hours is
not reported; a perfectly flat heart rate yields **no** score rather than a
middling one, because there is no personal range to position within; and a
banner states plainly that the band's own recording is not being used, and why.

HRV, RMSSD, SDNN, the Baevsky index and any recovery score stay absent — this
firmware sends no RR intervals (findings-20), and `HrvMetrics` remains
implemented, tested and unfed.

---

## 3. Sync and fetch defects found along the way

**The watermark went backwards 3.9 days.** `last_activity_sync.txt` read
2026-08-08 23:26 while the store held 6 406 newer samples through 08-12 20:56. A
manual deep sync returned a contiguous 08-05→08-08 batch and its newest sample
was assigned straight over the watermark. Now monotonic.

**And `addSamples` still stamped it from the wall clock.** Commit 49dafb9
removed that from `ble_manager.dart` and missed the copy in the store; it stayed
invisible because the fetch path overwrites it a few lines later. These two had
to be fixed together — a monotonic setter *alone* is worse than neither, because
a wall-clock stamp is always in the future relative to the real newest sample,
so the correct value could never win. The 226-test suite passed with that
combination, which is why `test/sync_watermark_test.dart` pins both halves.

**And it could sit behind data already held**, so the app re-fetched the same
361 samples every ten minutes forever. The watermark is now advanced to the
newest stored sample before the window is chosen.

**56% of the activity store was redundant.** `_fetchStartTime` kept the seconds
from `since`, but `_buildFetchCommand` transmits year…minute only — those
seconds are invented app-side and then stamped onto every sample. With the store
keyed on exact epoch-milliseconds, two fetches a few seconds apart stored two
copies of every minute: 69 419 samples over 30 447 real minutes, 117 distinct
offsets, up to 32 copies of one minute, **0 payload conflicts**. The zero
conflicts are what prove the minute index was always right and only the fraction
was spurious, so collapsing them on load is lossless. On the device:
4.88 MB → 2.17 MB.

It matters beyond disk space — the deep-sleep staging windows are indexed by
position rather than time, so duplicated minutes silently narrowed them. **The
deep-sleep calibration table in `sleep_analyzer.dart` was derived on the
duplicated captures and should be re-checked before it is trusted.** Median deep
share moves 13.7% → 13.2% across 18 nights, but individual nights shift more
(06-27: 33 → 10 min).

**Packet counters were read only to be logged**, and a 15-second stall completed
the fetch with a partial buffer. On an 8-byte grid a single dropped packet
shifts every remaining sample's timestamp, so a truncated buffer is not "some of
the data" — everything after the cut is stamped with the wrong minute. Both are
now failures that discard, following Gadgetbridge
(`AbstractFetchOperation.java:130-137`). Expect fewer, cleaner syncs and more
"no new data" lines. That is the intended trade.

---

## 4. Explicitly refuted — do not re-derive these

| Claim | Status |
|---|---|
| "The 0x13 buffer is byte-for-byte the activity stream from `since`" | **Overstated.** One round matches 95% of its comparable extent; another only as a ~360-minute prefix before decaying; a third 7.6%. Say "at least one capture shows the 8-byte activity layout at the same origin", not an identity. |
| "The band ignores the fetch-type byte" | **Not established.** An app-side buffer leak predicts the same shape. Probe P1. |
| "Discarding the echoed start timestamp causes a −233 byte mis-origin" | **Withdrawn.** All 985 overlapping activity round-pairs align at lag 0. Adopting the echoed timestamp (P2) is protocol-fidelity hardening, not a fix. |
| "HR and SpO2 watermarks regress identically" | **No live bug.** Neither has any reader; only `_lastActivitySync` feeds a fetch window. Made monotonic for consistency, claiming nothing. |
| "Duplicates inflated time in bed and efficiency" | **No.** Durations are wall-clock and zero-length intervals are dropped; efficiency moves ≤2 points on the worst nights and 0 on last night. Duplication corrupts deep-sleep *staging* instead. |
| "Guard on ≥90% of offset-6 bytes == 0x80" | **Wrong threshold.** `ds == 0x80` holds for 83.5% overall and 62% overnight. The 100% invariants are `ds >= 0x80` and `rs == 0`. |
| "Advance the stress watermark to the newest reading received" | **Would brick stress sync.** Seeding from the current data sets it to 2026-08-18 / 2105 → `since` permanently in the future. Any stress watermark must be `max(existing, newest)` clamped to `now`, and must not advance when a stream returned nothing. |
| "The hero shows 0 / Relaxed / green" | **Worse:** `inMinutes.abs() <= 60` truncates toward zero, so a future-dated row wins and it rendered **96 / High / red**. |
| Adding an ACK on the error or stall path | **Rejected.** That tells the band to drop bytes we never received. Withholding it is correct. |
