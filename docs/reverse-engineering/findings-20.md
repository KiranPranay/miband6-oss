# findings-20 — Stress is real; HRV is not

**Date:** 2026-08-09
**Scope:** native stress fetch, `0x2A37` flags decode, `stress_analyzer.dart`,
Stress screen, Gate 10. `flutter analyze` clean; `flutter test` 186/186 at
commit time.

> Not hardware-verified. §P6 in `pending-hardware-verification.md`; **P6.5**
> (the RR probe) is what could overturn the central conclusion below.

## 1. The app was wrong about stress

The Heart screen said stress "needs heart-rate variability (HRV) — coming soon".
That premise is false.

**Mi Band 6 computes stress on-device**, on the plain legacy path, and exposes
it through the ordinary activity-fetch channel:

| Type | Meaning | Payload |
|---|---|---|
| `0x13` | all-day / automatic | bare stream, **1 byte per minute**, 0-100, `0xFF` = no measurement |
| `0x12` | manual / spot | **5-byte records**: `uint32 LE` epoch-seconds + `uint8` score |

Neither carries a version byte (SpO2 `0x25` does — that asymmetry is easy to get
wrong). `MiBand6Coordinator.supportsStressMeasurement()` returns true; Mi Fit's
`MiLiProProfile` does the same thing under the name "pressure".

Enabling all-day recording is `FE 06 00 01` on the config characteristic — a
command already shipped in findings-19.

**The `0xFF` gap still consumes its minute.** Skipping it instead of advancing
the clock would shift every subsequent reading earlier; there is an explicit
test for this.

## 2. HRV genuinely is not available

Real HRV needs beat-to-beat (RR) intervals. The BLE Heart Rate Measurement
characteristic *can* carry them — flags bit 4 — but:

- **all 34 captured notifications** from this firmware, across 8 hardware runs,
  are exactly 2 bytes with flags `0x00` (bit 4 clear);
- Gadgetbridge's Huami path never even looks: `HuamiSupport.handleHeartrate`
  hard-guards `length == 2 && value[0] == 0`, so an RR-carrying packet would be
  silently discarded rather than decoded (GB has a correct parser in
  `HeartRateProfile`, but it is only wired to non-Huami devices);
- the HRV fetch type `0x49` is gated on `supportsHrvMeasurement()`, overridden
  only by `ZeppOsCoordinator` — GB never sends it to a Mi Band 6.

Our own parser was worse than GB's: `data[1] & 0xFF` after a length check, which
ignores the flags byte entirely. That is *accidentally* right for this firmware
but fails silently two ways — a uint16 heart rate would be read as its low byte
and look plausible, and RR intervals would never be noticed.

`lib/core/heart_rate_measurement.dart` now decodes the characteristic to spec
(uint8/uint16 HR, sensor contact, energy expended, RR in 1/1024 s units) and
**logs loudly** if RR intervals ever appear, so this conclusion can be revisited
rather than assumed permanent. That is the probe.

## 3. What the analyzer does with that

`stress_analyzer.dart` keeps two things strictly apart, because conflating them
is how health apps end up lying:

1. **`HrvMetrics`** — RMSSD, SDNN and the Baevsky stress index, implemented to
   the published definitions (Task Force of the ESC/NASPE, *Circulation* 1996;
   Shaffer & Ginsberg, *Front. Public Health* 2017; Baevsky & Berseneva) and
   tested against hand-computed values. **Nothing feeds it today.** It exists so
   the maths is right if RR data ever appears, and so the fallback below is an
   explicit choice rather than a silent substitution.

2. **An HR-deviation estimate** — how far the recent heart-rate average sits
   within the user's own rolling 7-day resting distribution (10th-90th
   percentile). Calibrated **per user**, so "elevated" means elevated for them.
   Its own explanation string says, verbatim, that it is *not* HRV.

Source selection is: a recent band measurement wins; then real RR if it ever
exists; then the HR-deviation estimate. **No score at all** is produced before a
personal baseline exists — the UI says how many readings remain instead of
showing a number.

## 4. Presented honestly

The Stress screen puts a provenance chip — "Measured by band" vs "Estimated by
app" — immediately next to the number, shows today's range and a 7-day trend,
and carries a plain-language method card. A breathing exercise is *suggested*
only on a calibrated elevated reading, never urged, and there is no medical
framing anywhere. Recovery remains omitted with its real reason.

## 5. Verified here

`test/stress_analyzer_test.dart` (28 tests): RMSSD/SDNN against hand-computed
alternating and ramp series, Baevsky rising as variability falls, outlier
filtering, the minimum-beats refusal; the full `0x2A37` decode including the
2-byte flags-0 form this firmware sends, uint16 HR not being read as its low
byte, RR conversion from 1/1024 s, energy-expended skipping, and truncated
packets being rejected rather than partially decoded; both stress record layouts
including the `0xFF` minute-consuming gap; and the source-selection rules.

One test failure during development was informative and kept as a fixture note:
a constant-60 bpm baseline makes p10 == p90, and the analyzer correctly refuses
to compare rather than dividing by zero.

## 6. Honest limits

- **No stress byte has been read from a real band.** The record layouts come
  from Gadgetbridge cross-checked against Notify and Mi Fit; P6.1-P6.3 are what
  confirm them, and P6.3 (timeline alignment vs Zepp Life) is what would catch a
  wrong stream start time.
- The Baevsky→0-100 mapping is a reasoned compression of a wide range, not a
  fitted curve. It only matters if RR data ever arrives.
- The HR-deviation fallback is a *proxy*, and is labelled as one everywhere it
  appears. It should not be compared against another device's stress score.
- `0x49` (HRV) has not been probed on our band the way `0x48` was; queued as
  P6.6 with `0x13` as a positive control.
