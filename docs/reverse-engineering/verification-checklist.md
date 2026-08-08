# Verification checklist — confirm the MB6 fixes on a real band

Run the app connected to the real Mi Band 6 and watch the logs (`_logger.i/d/e`).
Each row maps a protocol claim to the exact log line that confirms it.

## Connect + auth (should be unchanged / still working)
| # | Expectation | Log line to look for |
|---|---|---|
| 1 | Legacy auth still succeeds | `Authentication SUCCESS!` |
| 2 | `0x180D` + `fee0` services discovered | `SERVICE UUID: …180d…`, `…fee0…` |

## Realtime heart rate (the headline fix)
| # | Expectation | Log line |
|---|---|---|
| 3 | HR chars found | `HR: 0x2A37 props notify=true …` |
| 4 | `0x2A37` CCCD enable now **succeeds** (the old `WRITE_NOT_PERMITTED` is gone) | `HR: notifications enabled on 0x2A37.` (and NOT `failed to enable 0x2A37 notify`) |
| 5 | Continuous start commands written | `HR: wrote stop-manual (15 02 00) to 0x2A39.` then `HR: wrote start-continuous (15 01 01) to 0x2A39.` |
| 6 | Realtime started | `HR: realtime measurement started.` |
| 7 | **Parsed BPM arrives** | `HR notify: 00 4b -> 75 bpm` (any value 7..249) |
| 8 | Keep-alive ping fires (~every 12 s) | `HR: wrote keep-alive (16) to 0x2A39.` |
| 9 | HR continues streaming for >30 s (keep-alive working) | repeated `HR notify: … -> NN bpm` lines past the first ping |
| 10 | One-shot path (if invoked via `measureHeartRateOnce`) | `HR: wrote start-manual (15 02 01) …` → a single `HR notify:` |

> If line 4 still shows `failed to enable 0x2A37 notify … WRITE_NOT_PERMITTED`,
> HR history is still captured from the activity fetch (line 14). Next debugging
> step would then be: ensure a fresh service discovery after auth, try toggling
> notify after a longer settle, or check Android bonding state — but per Notify/GB
> this CCCD is permitted on MB6, so it should now succeed.

## Battery
| # | Expectation | Log line |
|---|---|---|
| 11 | Battery read from `fee0/0x0006`, level = byte[1] | `Battery (0x0006): 87%` (plausible value, optionally `(charging)`) |
| 12 | (fallback only if 0x0006 absent) | `Battery (0x2a19): NN%` |

## Activity / sleep / HR-history fetch
| # | Expectation | Log line |
|---|---|---|
| 13 | Fetch accepted, non-zero length | `ActivityFetcher: expected data length = <N>` (N>0) |
| 14 | 8-byte samples parsed; HR derived | `Activity fetch: got <K> samples` then `HR history: derived <M> readings from activity` |
| 15 | Steps look sane (≤255/min, monotonic-ish totals); sleep stages present overnight | inspect parsed `ActivitySample` (cat/sleep/deep/rem) in stored data |
| 16 | SpO2 fetch uses correct type | `ActivityFetcher: requesting data type 0x25 since …` |

## Sanity / regression
| # | Expectation | Log line |
|---|---|---|
| 17 | Realtime steps still work | `Steps: <n>, <m> m, <c> kcal` |
| 18 | On disconnect, keep-alive timer stops, HR state reset | `Device disconnected.` then no further `HR: wrote keep-alive` |

## Pass criteria (Definition of Done)
- Lines **4 + 7** present ⇒ realtime HR returns a parsed BPM via the standard
  `0x2A37/0x2A39` channel. ✅ core deliverable.
- Line **14** present ⇒ activity fetch returns parsed samples (incl. HR history).
- Line **11** present ⇒ battery via `fee0/0x0006`.

---

# Additions from the 2026-08-09 overhaul (findings-15 … 20)

Every new protocol claim below has a greppable log line. Run the gated session
and `grep MB6TEST` plus the specific lines named here.

## Performance (findings-15) — no protocol claims
| # | Expectation | Log line / check |
|---|---|---|
| 19 | Service discovery happens ONCE per connection, not ~9× | exactly one `Discovering services...` per connect |
| 20 | Verbose packet logging is off by default | no `[DEBUG]` lines until the console's eye toggle is used |
| 21 | Store is loaded once, not twice, at startup | one burst of store activity on launch |

## Connection supervisor (findings-16)
| # | Expectation | Log line |
|---|---|---|
| 22 | Retry follows 1/2/5/15/30/60 s | `Supervisor: retry #<n> in <d> s` — deltas must match |
| 23 | Adapter off pauses retries | `Supervisor: Bluetooth adapter OFF — pausing reconnects` and **no** retry lines after it |
| 24 | Adapter on resets the backoff | `Supervisor: Bluetooth adapter ON` then a retry at ~1 s, not 60 s |
| 25 | Half-open link is detected | `no packet for <n> min while connected — forcing a reconnect cycle` |
| 26 | Settings are re-applied after re-auth | `BandConfig: re-applying all settings (post-auth)` |
| 27 | HR streaming is restored only if it was on | `HR: streaming stays off (user had it disabled).` when it was off |

## Notifications (findings-17)
| # | Expectation | Log line |
|---|---|---|
| 28 | Warm engine is up | `Warm FlutterEngine started and cached as 'band_engine'` (logcat, tag `BandApplication`) |
| 29 | Listener is bound | `Notification listener connected` (tag `BandNotifListener`) |
| 30 | Listener recovers after an unbind | `Notification listener disconnected — requesting rebind` |
| 31 | Nothing is dropped silently | every drop logs `Notif relay: dropped "<app>" — <reason>` |
| 32 | Payload is chunked correctly | `Notif: sent app "<x>" — <n> B in <k> chunk(s) of ≤<m> B (mtu=<mtu>…)` |
| 33 | Call alerts use ANS | `Found ANS NEW_ALERT characteristic (0x2A46) for call alerts` then `Notif: sent call "<x>" … to 0x2A46` |
| 34 | Gate 8 writes an alert | `MB6TEST GATE8: PASS — alert written to 0x0020 in <k> chunk(s)` + **visual confirmation** |

## Sleep (findings-18)
| # | Expectation | Log line |
|---|---|---|
| 35 | Kind-byte distribution is recorded (settles protocol §7.2) | `MB6TEST GATE7: kind-byte histogram: …` |
| 36 | A plausible night is produced | `MB6TEST GATE7: PASS — night=<m>m deep=<p>% eff=<e>% wakes=<w>` |
| 37 | REM is never reported | Gate 7 FAILS if REM > 0 — its absence in the pass line is the check |
| 38 | Desk band produces no session | leave the band off overnight ⇒ no session for that night |

## Band settings (findings-19)
| # | Expectation | Log line |
|---|---|---|
| 39 | Every config command is accepted | `BandConfig: <label> → <target>: <bytes>` per command, no `write failed` |
| 40 | HR interval is in minutes | `BandConfig: HR interval 5 min → heartRateControl: 14 05` |
| 41 | Wear wrist goes to user settings, not config | `→ userSettings: 20 00 00 02` |
| 42 | Gate 9 passes | `MB6TEST GATE9: PASS — <n> config commands accepted` |
| 43 | **Interval actually changes the cadence** | per-minute HR samples in the next fetch after setting 1 min (P3.2) |

## Stress + HR flags (findings-20)
| # | Expectation | Log line |
|---|---|---|
| 44 | All-day stress fetch requested | `ActivityFetcher: requesting data type 0x13 since …` |
| 45 | Manual stress fetch requested | `ActivityFetcher: requesting data type 0x12 since …` |
| 46 | Stress readings arrive | `Stress fetch: <n> all-day + <m> manual readings` |
| 47 | Gate 10 passes or explains | `MB6TEST GATE10: PASS — …` or the SKIPPED line naming the disabled toggle |
| 48 | **RR intervals absent (or present!)** | `HR: RR INTERVALS PRESENT (…)` must NOT appear; the verbose `HR notify: … rr=0` line confirms the flags byte |

## Pass criteria for the overhaul
- `MB6TEST SUMMARY p=11 s=0 gates=[0:P … 10:P]` with the band worn and all-day
  stress enabled ⇒ everything added this pass works on hardware.
- Anything less: the failing gate names the section of `protocol-mb6.md` to
  re-check.
