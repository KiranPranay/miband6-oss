# Changelog

Notable changes, newest first. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project has not
cut a tagged release yet, so everything sits under *Unreleased*.

Entries say what changed **and what was wrong**, because in a health app the
second one matters to anyone whose history just moved.

## [Unreleased]

### Added — overnight, 2026-09-23

- **Deep sleep is back, as a labelled estimate.** The findings-24 detector was
  withdrawn because its output was uniform across the night. The replacement
  detrends heart rate with a whole-session line (no edge bias) and requires a
  deeper dip the later it is, per Borbély's two-process model — so front-loading
  is a property of the rule, not luck. On 53 real nights: 14.2% median share,
  bout position 0.446, one empty night. Every surface says "est."; score weight
  20%, below both measured components. See findings-25.
- **The band's buttons now reach the phone** (protocol §12). Reject on the
  wrist ends the call; ignore silences the ringer; find-my-phone rings it at full
  volume until the band says stop. Needs the phone/SMS permissions, requested
  from Band settings with the reason beside the button.
- **Calls are routed as calls.** Incoming-call notifications were forwarded as
  plain text, so the wrist had nothing to press. They now use the band's call
  alert, and when the phone's call notification goes away the band's screen is
  cleared too.
- **Decline with a text.** Optional; phone-side; sends a preset SMS to the caller
  when you decline from the band, if the call notification carried a number.
- **The band's own sleep boundaries** (FELL_ASLEEP / WOKE_UP / off-wrist) are
  recorded to `band_events.json`. Whether they should anchor session detection
  is probe P12.3.
- **Sessions no longer depend on the band's flag alone.** A night worn
  end-to-end at 97% heart-rate coverage produced nothing because the band
  flagged 20% of its minutes; Chinoy actigraphy now anchors too, corroborated
  per minute by heart rate below the waking median, with sustained onset and a
  12-hour split. A night that still cannot be classified is shown as what was
  measured — "restless, not staged" — never as sleep, and never as a nap
  standing in for last night. See findings-26.
- **Charts you can read.** Round axis ticks, clock labels (12a · 6a · 12p ·
  6p), a "now" marker, a numbered scale on the hourly steps chart, no REM lane.
- **The ledger.** Every number is a monospace tabular figure; metric grids
  became ledger rows with dotted leaders and one-line notes; each group and the
  Today score carry an evidence line — "1 440 samples today · synced 3m ago".
  The chart comes first on each detail tab. Naps get a nap card, not a night's
  score. The Sleep tab steps between nights with chevrons.
- **Two experimental switches, off by default**, each a documented probe: ask
  the band to sample SpO2 automatically (P14.2 — no phone-triggered
  measurement exists on this firmware path, §14), and quick replies on the band
  (P13.1 — the receive path is disabled upstream as "unsafe"). Both say
  "unverified on Mi Band 6" on the switch.

### Fixed — the second look, 2026-09-23

Walking the phone after the design pass, with the screens side by side.

- **Notifications spoke a different dialect.** Reached from Settings, it had
  a bold sans title, two hand-rolled cards and a bare checkbox list. It now
  uses the same overline labels, group surfaces and rows as Settings, and the
  app list sits on one surface too. Search takes the screen over: the setting
  groups fold away while you type so the matches sit under the field, above
  the keyboard; the count reads "3 matches · 18 selected"; no match reads the
  query back; a clear button restores the groups. Six widget tests pump it at
  phone size, with a keyboard up, and at a very short viewport.
- **Tap ink was invisible on every grouped row.** A ListTile paints its ink on
  the nearest Material, and GroupCard put a coloured box in between, so
  Settings logged "ink splashes may be invisible" for every tappable row. The
  group surface is a Material now; the outer box carries only the shadow.
- **"Average HR 0 bpm lower than last week"** is now "unchanged from last
  week". A zero dressed as a comparison said nothing.
- **Profile named the band twice** — in the header and in the card beneath.
  The header line now says the one thing the card does not: how far back the
  record goes ("Recording since 28 Jul").
- **The relay's source file was binary to every tool.** Its dedup key was
  written with literal NUL bytes; grep skipped the file and `file` called it
  data. Same key, as escapes.
- **The scanner's spinner was white on white** in light mode.
- **An unknown battery looked like a dead one.** While the band was still
  reconnecting the Profile card showed "--%" with the red low-battery icon;
  unknown is now neutral grey.

### Fixed — after several weeks of real use

An audit over the live capture (38 071 activity samples, 81 471 heart-rate
readings) plus a five-day sync outage the app never reported. Ranked by what a
user would actually have seen.

- **History sync deadlocked and stayed frozen for five days.** The repeating
  fetch started ten minutes *behind* the watermark but advanced only as far as
  the band's next gap — often ten minutes — against a twelve-round cap. With a
  six-hour overlap it needed 36 rounds to reach ground it already had, so every
  sync did work and finished exactly where it began. Budgeted by wall-clock time
  now, and the recent window is fetched first so today is never hidden behind a
  backfill.
- **"Synced just now" was measured from the wrong thing** — re-stamped by every
  step packet and heartbeat, so the one staleness indicator read healthy
  throughout the outage.
- **Deep sleep was withdrawn, not re-calibrated.** Its share could be tuned from
  5% to 19% — anywhere inside the published healthy band — while the minutes it
  picked stayed spread evenly across the night. Real slow-wave sleep is
  front-loaded. See findings-24.
- **A 52-day-old SpO2 reading was shown as today's**, and on the Sleep tab a
  night with no reading displayed the all-time average as that night's
  measurement — the same fabricated "97% · Normal" on 22 of 23 nights.
- **Wake-ups counted classifier noise**: 38 became 6 once the audited
  ≥5-minute count the repo already had was actually used.
- **"Last night" could be any night**, and among candidates picked the longest
  rather than the most recent.
- **Days the app never received were compared as if complete** — a day with 167
  of 1440 minutes and 73 steps was "yesterday" for comparison purposes, and sat
  inside the personal baseline.
- **Corrupt transfers were parsed anyway.** The integrity guard returned an
  empty list; the callers ignored it and re-parsed the damaged buffer.
- **History could vanish on a crash** — non-atomic writes, a silent catch-all on
  load, and a save that would then overwrite the remains with nothing.
- **The auth key was written to the log**, and release builds echoed everything
  to logcat. **Android Auto Backup was on**, contradicting the privacy promise
  in the README.
- **A fabricated user profile** (male, 1990, 175 cm, 70 kg) was written to the
  band on every connection, overwriting the user's own and driving the band's
  distance and calorie maths.
- **The band's configured step goal was ignored**; both screens hardcoded 10 000.
- **Stress was partly a step counter** — no exclusion of minutes spent walking,
  though the step data sat in the same store.
- **Sleep sessions crossing 18:00 overlapped** and double-counted up to an hour.
- Plus: every connect scheduled a competing reconnect, several notification
  subscriptions leaked per reconnect, unrecorded days were drawn as zero-step
  bars, the store had no retention and rewrote 4.9 MB on every save, and the
  Sleep tab re-derived the entire sleep history on every rebuild.


### Open-source release

- AGPL-3.0-or-later licence, with attribution headers on the two files
  translated from Gadgetbridge and full third-party notices in `NOTICE.md`.
- README, contributing guide, security policy, code of conduct, issue and PR
  templates, and CI (analyze, test, debug APK, licence hygiene).

### Fixed — sync

- **History sync stopped a few hours into every session.** `_fetchActivityData`
  built a new `ActivityFetcher` per call and never disposed the previous one, so
  each sync left another live notification subscription. Two listeners meant the
  metadata frame was handled twice, `0x02` was written twice, and the band
  answered `10 02 04` — error — instead of streaming. Steps froze while the
  band's own counter kept climbing.
- **One fetch round could never pass a gap.** The band serves a contiguous run
  and stops at the first discontinuity in its ring buffer; a single request
  therefore made every gap permanent. Sync now repeats from the last received
  timestamp until the band runs dry. One real day needed five rounds.
- **The sync watermark could move backwards**, and `addSamples` still stamped it
  from the wall clock — two defects that hid each other, since fixing only the
  second reinstates the first.
- **56% of the activity store was duplicate minutes.** The fetch start kept
  seconds that are never sent to the band, so overlapping fetches stored a
  second copy of every minute. Activity samples now de-duplicate by minute;
  heart rate keeps millisecond keys, where sub-minute readings are real.
- Broken transfers are discarded rather than stored: packet-counter gaps and
  stalls now fail the fetch. On an 8-byte grid a dropped packet shifts every
  later timestamp, so a partial buffer is not partial data — it is wrong data.

### Fixed — sleep

- **Time in bed was inflated on nights with wake gaps.** The sleep test accepted
  kind-byte nibbles 9 and 11 even when the band was not flagging sleep; three
  such samples stitched one night across two 70-minute gaps, turning 6h29m in
  bed into 8h41m and 61% efficiency into 45%. The band's `0xF` flag is now the
  only sleep signal.
- Sleep depth is decided from heart rate alone. Staging read it from the same
  discredited nibble, which survived on nights where HR coverage was too thin
  for the refinement pass to run.
- Awakenings are counted at ≥5 minutes, the usual actigraphy threshold. Of one
  night's 35, eighteen were single minutes at which heart rate sat *below* the
  surrounding median. The Chinoy wake threshold itself was deliberately not
  retuned; short blips still count towards wake time.

**Historical sleep values changed.** Across 18 nights, median efficiency moved
68% → 71% and median time in bed 476 → 437 minutes.

### Changed — stress

- **The band's stress stream is quarantined.** All 26,863 stored readings
  decoded as 8-byte activity records: parsed one byte per minute, the clock ran
  eight times fast and 63% were dated *after* they were fetched. One "stress
  score of 64" hand-decodes to that minute's heart-rate byte. The old data is
  preserved as `stress_data.v0-unverified.json` rather than deleted.
- Whether the band serves activity for these fetch types, or our own transfer
  leaks into the buffer, is unresolved — probe P9.1.
- **Stress history now exists**, derived from stored heart rate: each hour's
  mean positioned within the user's own range *for that time of day*, since
  resting HR varies across the 24-hour cycle by more than the effect measured.
  The screen states plainly that it is an estimate.

### Fixed — UI

- **One stale palette explained most of the "inconsistent UI".** Design tokens
  are global getters read at build time, and Flutter never rebuilds an unchanged
  `const` widget — so anything built during Android's briefly-wrong cold-start
  brightness kept light-mode colours forever. That produced near-invisible
  headings and one pure-white card in the middle of a dark screen.
- The floating nav no longer clips the last card: every tab reserved a flat
  96 px against a nav that is taller than that once the gesture inset is added.
- All five tabs share one header. Two of them had none, so their content
  scrolled up behind the status bar.
- Charts stopped overstating: the heart trend plotted sample *index* as if it
  were time, activity sub-scores showed formula weights where a reader sees
  achievement, and a "This week" summary covered 1 July to 10 August.
- Enabled switches were a featureless pill — the thumb had been given the track
  colour at four call sites.

### Added

- Sleep Regularity Index (Phillips 2017; UK Biobank reference values).
- Low-power overnight sleep-capture mode, with the streaming intent persisted
  across restarts.
- Light and dark themes with contrast enforced by test.
- `tool/analyze_capture.dart` — replays a real capture through the shipping
  analysis code and checks it against published norms. This is how most of the
  data defects above were found.

---

## Earlier work

Before this changelog began, the project reached a working state across
several iterations, each recorded in
[`docs/reverse-engineering/`](docs/reverse-engineering/):

| Area | Document |
|---|---|
| Sign-key (ECDH) authentication — the unlock for everything else | `findings-06`, `findings-07` |
| SpO2 parser, hand-decoded from real bytes | `findings-08` |
| Sleep-stage decode; no `0x48` session stream on this band | `findings-09` |
| Overnight snoring detection | `findings-10` |
| Per-screen trust passes (Sleep, Heart, Activity, Today) | `findings-11`–`14` |
| Performance — the cause of the UI lag | `findings-15` |
| Background connection supervisor | `findings-16` |
| Notifications — the warm-engine fix and five payload defects | `findings-17` |
| Band settings, every command with its characteristic | `findings-19` |
| The sleep encoding, settled on 60,404 live samples | `findings-21` |
| First on-device dark-mode pass | `findings-22` |
| The stress data was never stress | `findings-23` |
