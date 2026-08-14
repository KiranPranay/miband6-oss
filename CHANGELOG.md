# Changelog

Notable changes, newest first. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project has not
cut a tagged release yet, so everything sits under *Unreleased*.

Entries say what changed **and what was wrong**, because in a health app the
second one matters to anyone whose history just moved.

## [Unreleased]

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
