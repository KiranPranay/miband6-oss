# findings-19 — Band settings: every command, and the characteristic it belongs to

**Date:** 2026-08-09
**Scope:** `lib/core/band_config.dart` (+ controller, UI, Gate 9).
`flutter analyze` clean; `flutter test` 158/158 at commit time.

> Not hardware-verified. §P3 in `pending-hardware-verification.md`; **P3.2** is
> the only check that can actually prove any of these bytes are right.

## 1. Why the target characteristic is part of the spec

The band **accepts and silently ignores** a command it does not understand.
There is no error, no status byte, no rejection — the GATT write succeeds and
nothing happens. So a wrong opcode *or a right opcode on the wrong
characteristic* produces a setting that looks fine in the UI and does nothing on
the wrist.

That makes routing a correctness concern, not a detail:

| Target | UUID | Used for |
|---|---|---|
| Configuration | `00000003-0000-3512-2118-0009af100700` | most settings |
| User settings | `00000008-0000-3512-2118-0009af100700` | wear wrist, user info, step goal |
| HR control point | `00002a39-…` (standard) | **all** HR mode/interval commands |
| Alert level | `00002a06-…` (standard) | vibrate / find band |
| Old chunked | `00000020-0000-3512-2118-0009af100700` | display items, vibration patterns |

The full command table is `protocol-mb6.md` §9. Each layout is unit-tested,
including the target.

## 2. Traps worth naming

- **HR interval is minutes, not seconds.** GB's UI takes seconds and divides by
  60 before sending; only the divided value goes on the wire. `0` disables.
  MB6 restricts the choices to 0/1/5/10/30.
- **Lift-wrist OFF is 4 bytes, ON is 8.** The 8-byte all-zero-schedule form
  means *always*, not *disabled*. Sending 8 bytes of zeros when you meant "off"
  turns it on.
- **DND + "allow lift wrist" clears bit `0x80`** of byte 1 (`0x81→0x01`,
  `0x83→0x03`) rather than adding a field.
- **Inactivity has two time windows** so a quiet period can be carved out of the
  middle of the day; with no carve-out bytes 8-11 stay zero.
- **Step goal and wear wrist are NOT on the config characteristic.**

## 3. What Mi Band 6 cannot do (and so is not offered)

| Setting | Why |
|---|---|
| SpO2 all-day monitoring | ZeppOS-only (`ZeppOsConfigService` HEALTH id `0x31`) |
| Sleep-breathing quality | ZeppOS-only (HEALTH id `0x12`) |
| **Low** HR alert | `setHeartrateAlert` encodes only the high threshold |
| Hourly chime | not sent for MB6 |

These are **absent from the UI**, not disabled. A greyed-out switch implies the
feature is nearly there; an absent one is honest.

## 4. Settings survive reconnects — and stop overwriting the user

`BandConfigController` persists the settings and re-applies **all** of them after
every successful auth. The band loses some across a reset, and Gadgetbridge
likewise re-sends on each connect rather than only at pair time.

This also fixed a live bug: `_onAuthSuccess` previously wrote **hard-coded**
values on every single connect — 24-hour time, date display, and a fixed
10,000-step goal — silently overwriting whatever the user had chosen. Those
three calls are deleted.

Writes are diffed: only commands whose bytes actually changed are sent when a
single toggle moves.

## 5. Optimistic UI with real rollback

`update()` applies the change locally and notifies immediately, then writes.
On failure the previous value is restored and an explanation is surfaced — the
switch visibly flips back. A switch that stays on while the band ignored the
command is a lie, and this protocol makes that failure mode easy to hit.

When the band is disconnected the setting is saved and applied on the next
connect; that is reported as a neutral state, not an error.

## 6. Verified here

`test/band_config_test.dart` (32 tests): every command's exact bytes **and its
target characteristic**, the minutes-not-seconds interval, the 4-vs-8-byte
lift-wrist forms, the DND bit-clearing variant, the 13-byte date-format command
with 10 ASCII bytes, uint16-LE step goal with clamping, the 12-byte inactivity
layout with both windows, and JSON round-tripping including corrupt input
falling back to defaults rather than throwing.

## 7. Honest limits

- **A successful write proves nothing.** Only P3.2 — setting the interval to
  1 minute and seeing per-minute HR samples in the next fetch — demonstrates the
  band acted on any of this.
- Display-item ordering is implemented as bytes but not exposed in the UI; it
  needs the chunked writer path and a picker.
- Scheduled lift-wrist / DND / night-mode windows are encodable but the UI only
  exposes the mode, not a time picker yet.
- Vibration patterns per notification type are not implemented.
