# test-results-02 — hardware run template (2026-08-09 overhaul)

Fill this in after running the gated session on the physical band. **Do not
edit `test-results-01.md`** — results are never overwritten.

## Run metadata

| Field | Value |
|---|---|
| Date / time | _pending_ |
| Firmware | _pending_ (from `MB6TEST SESSION START … fw=`) |
| Phone / Android version | _pending_ |
| Band worn? | _pending_ (HR/stress/sleep gates need it) |
| All-day stress enabled? | _pending_ (Gate 10 needs it) |
| App commit | _pending_ |

## Gate summary

Paste the one-line summary:

```
MB6TEST SUMMARY p=? s=? gates=[0:? 1:? 2:? 3:? 4:? 5:? 6:? 7:? 8:? 9:? 10:?] fw=?
```

| Gate | What it proves | Result | Notes |
|---|---|---|---|
| 0 | services discovered | | |
| 1 | sign-key auth intact **(regression gate)** | | |
| 2 | battery via `fee0/0x0006` | | |
| 3-5 | realtime HR + keep-alive | | |
| 6 | activity fetch, 8-byte layout | | |
| 7 | plausible sleep session (findings-18) | | |
| 8 | notification written **(needs visual confirmation)** | | |
| 9 | band settings accepted (findings-19) | | |
| 10 | native stress fetch (findings-20) | | |

## Gate 7 — the kind-byte question (P2.1)

This settles the open contradiction in `protocol-mb6.md` §7.2: Gadgetbridge's
legacy table says sleep is kind **9/11**, but our captures showed **0xF0/0xF3**.

Paste the histogram line:

```
MB6TEST GATE7: kind-byte histogram: …
```

**Verdict:** _does this firmware use 9/11, the 0xF0/0xF3 high-nibble form, or
something else?_ → update `protocol-mb6.md` §7.2 and the analyzer accordingly.

## Sleep accuracy vs Zepp Life (P2.3)

The only real accuracy check. Same night, both apps:

| Metric | This app | Zepp Life / Mi Fit | Delta |
|---|---|---|---|
| Bedtime | | | |
| Wake time | | | |
| Total sleep | | | |
| Deep | | | |
| Light | | | |
| Awake | | | |
| Wake episodes | | | |
| Efficiency | | | |

Old vs new pipeline on the same data (P2.6, via `computeSleepDaysLegacy()`):

| | Legacy | New |
|---|---|---|
| Total | | |
| Deep % | | |
| Sessions detected | | |

## Notifications (P5)

| Check | Result |
|---|---|
| P5.1 Gate 8 alert visible on band | |
| **P5.2 delivery after swiping the app away** (the main fix) | |
| P5.3 WhatsApp/Signal text not blank | |
| P5.4 long text chunked, not truncated | |
| P5.5 incoming call via `0x2A46`, clears on hang-up | |
| P5.6 dedup / privacy / screen-on | |
| P5.7 icons correct | |
| P5.8 rebind after reinstall | |

## Band settings (P3)

| Check | Result |
|---|---|
| P3.1 all config writes accepted | |
| **P3.2 HR interval actually changes sample cadence** | |
| P3.3 visible settings correct on the band | |
| P3.4 re-applied after reconnect | |
| P3.5 rollback on failure | |

## Stress (P6)

| Check | Result |
|---|---|
| P6.1 Gate 10 returns readings in 0..100 | |
| P6.2 toggle off ⇒ no data, on ⇒ data | |
| P6.3 timeline matches Zepp Life | |
| P6.4 manual measurement arrives | |
| **P6.5 RR intervals present? (continuous AND one-shot)** | |
| P6.6 fetch `0x49` result | |

Flags byte observed: continuous `0x__`, one-shot `0x__`.
If either shows bit 4 set, `findings-20` §2 must be revised and real HRV becomes
possible.

## Connection (P4)

| Scenario | disconnect → ready | Notes |
|---|---|---|
| Airplane mode off→on | | expect ~1 s after adapter ON |
| Walk back into range | | |
| Band reboot | | includes full sign-key re-auth |
| Half-open link | | detection ≤6 min |
| Task removal | | service survives? |
| Phone reboot | | respects "wants connected" |

## Performance (P1)

| Screen | Dropped frames before | After | Worst frame (ms) |
|---|---|---|---|
| Today | | | |
| Sleep | | | |
| Heart | | | |
| Activity | | | |

Connect → authenticated → first metrics: _before_ ___ s / _after_ ___ s.

## UI (P7)

| Check | Result |
|---|---|
| P7.1 dark mode looks right on every screen | |
| P7.2 live OS theme switch | |
| P7.3 largest font size, no clipping | |
| P7.4 reduced motion respected | |
| P7.5 TalkBack pass | |

## Regressions found

_List anything that worked before this overhaul and does not now. The Gate 1
auth check is the most important: it must not have regressed._
