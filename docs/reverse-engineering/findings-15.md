# findings-15 — Performance: why the app lagged, and what changed

**Date:** 2026-08-09
**Scope:** UI/runtime performance only. **No protocol bytes changed**, no BLE
opcode touched, no change to the sign-key (ECDH) auth path. `flutter analyze`
clean; `flutter test` 80/80 green (61 pre-existing + 19 new).

> Hardware note: no adb device was attached for this session (`adb devices`
> empty, no Android device on USB), so the on-device profile-mode frame capture
> is **queued**, not done — see `pending-hardware-verification.md` §P1. Every
> claim below is either a code-level fact or covered by a unit test; none of them
> are presented as measured device frame times.

---

## 1. Root cause

The lag was not one bug; it was a chain where each link multiplied the next.

**Link 1 — every BLE event notified the whole app.**
`BLEManager extends ChangeNotifier` and called `notifyListeners()` from every
update path: heart-rate notify, steps notify, battery notify, auth step, fetch
progress. `BLELogger` did the same *per log line*.

**Link 2 — every screen subscribed to everything.**
Each tab began its `build()` with a top-level `context.watch<BLEManager>()`:

| File | Line (before) |
|---|---|
| `lib/ui/tabs/sleep_tab.dart` | `final ble = context.watch<BLEManager>();` (2 082-line widget) |
| `lib/ui/tabs/activity_tab.dart` | same |
| `lib/ui/tabs/heart_tab.dart` | same |
| `lib/ui/tabs/today_tab.dart` | same |

So *any* notification rebuilt the entire visible tab.

**Link 3 — `build()` did the heavy lifting.**
Those rebuilds re-ran the analysis engines from scratch:

- `today_tab.dart` called **all three** — `store.computeSleepDays()`,
  `SleepAnalysis.compute`, `HeartAnalysis.compute`, `ActivityAnalysis.compute`.
- `computeSleepDays()` copies **and sorts the entire sample history**, then walks
  it — and was called several times per build (sleep card, score, briefing).

**Link 4 — the store did O(n) work per heartbeat.**
`ActivityStore.addHeartRateReadings()` built a `Set` of **every stored HR
timestamp** and re-sorted the whole list *on every call* — and it is called once
per streamed beat from `_onHeartRateNotified`.

**Link 5 — disk I/O inside notify callbacks.**
`_applyStepsPacket()` called `_storage.saveMetrics()` + `saveLastSyncTime()`
synchronously in the steps-notify path. `ActivityStore.save()` JSON-encoded the
full history on the UI isolate.

**Link 6 — unbounded log buffer.**
`BLELogger._logs` was an unbounded `List<String>`, appended for the life of the
process, and `logs` returned `List.unmodifiable(_logs)` (an allocation per read).

Net effect with realtime HR streaming on: ~1 notify/s from the band, each one
rebuilding a 2 000-line widget tree, re-running three O(n) analyses, rebuilding
an O(n) dedup set, and touching disk.

**Bonus defect found while reading:** `BLEManager`'s constructor called
`activityStore.load()` *and* `_loadPersistedData()` — which itself calls
`activityStore.load()`. The whole history was parsed from JSON **twice** on every
app start. Fixed.

---

## 2. Fixes

### 2.1 Rate-limiting primitives — `lib/core/ui_throttle.dart` (new)

- `Coalescer` — leading-edge + single trailing invocation, default 250 ms
  (≈4 Hz). A burst of 200 synchronous events runs the action twice, not 200×,
  and the *last* value is never dropped.
- `Debouncer` — trailing-only, with `isPending` so shutdown paths can flush.

### 2.2 Fine-grained UI state — `ble_manager.dart`

High-frequency values each get a dedicated `ValueNotifier`, so a widget
subscribes to exactly what it renders:

`heartRateListenable`, `batteryListenable`, `metricsListenable`,
`authStateListenable`, `fetchingListenable`, `realtimeHrListenable`.

`notifyListeners()` is now reached only through `_emitChange()` (coalesced to
~4 Hz) or `_emitImmediate()` (user-initiated transitions such as Connect, where
a 250 ms trailing delay would be felt). **`_onHeartRateNotified` no longer calls
`notifyListeners()` at all** — it only sets `heartRateListenable`.

### 2.3 Selective subscription — the tabs

Each tab now takes `context.read<BLEManager>()` (no subscription) and wraps its
body in a `ListenableBuilder` over `Listenable.merge([...])` of only the signals
it renders:

| Tab | Subscribes to |
|---|---|
| `sleep_tab` | store revision, fetching |
| `activity_tab` | store revision, auth, fetching, metrics |
| `heart_tab` | store revision, auth, **heart rate**, realtime-HR flag |
| `today_tab` | store revision, auth, fetching, metrics, battery, **heart rate** |

Sleep and Activity no longer rebuild on a heartbeat at all. Heart and Today
still do — they display the live number — but the rebuild is now cheap (§2.4).

### 2.4 Memoised analyses — `lib/core/analysis_cache.dart` (new)

Keyed on `ActivityStore.revision`, which advances **only when stored data
actually changes**:

- `AnalysisCache.heart` — caches the aggregate with `currentBpm: null`, then
  applies the live bpm via the new `HeartAnalysis.withCurrentBpm()`. `currentBpm`
  feeds only `currentBpm`/`currentStatus`; every other field is an aggregate, so
  a heartbeat costs one small object instead of a full pass. The projection is
  cached too, so a repeat build at the same bpm returns the identical instance.
- `AnalysisCache.activity` — keyed on revision + live steps + goal + **the
  current minute** (the engine uses "now" for pace/projection, so it must expire
  with the clock — once a minute, not once a frame).
- `AnalysisCache.sleep` — keyed on revision + session start.

`ActivityStore.computeSleepDays()` is additionally memoised inside the store, so
the several calls within a single Today build collapse to one.

The engines stay pure and directly unit-testable; the cache only decides *when*
to call them.

### 2.5 Store — `activity_store.dart`

- Incremental dedup indexes (`_sampleKeys`/`_spo2Keys`/`_hrKeys`) maintained on
  add, replacing the per-call `Set` rebuild. `_mergeSorted()` sorts **only** when
  an item actually lands out of order, so the two common cases — a live sample
  appended at the end, and an already-sorted fetch batch — are O(k) in the number
  of *new* items.
- `save()` JSON-encodes via `compute()` on a background isolate.
- `revision` + `revisionListenable` added; `purgeOlderThan` now also purges HR
  readings (it previously leaked them forever) and rebuilds the indexes.

### 2.6 Notify paths no longer touch disk

`_applyStepsPacket` → `_metricsSaveDebouncer` (5 s);
`_onHeartRateNotified` → `_storeSaveDebouncer` (10 s).
`_handleDisconnect` calls `_flushPendingWrites()` so a disconnect — often the
last event before the process is backgrounded — cannot lose buffered state.

### 2.7 Logger — `logger.dart`

Rewritten: bounded `ListQueue` ring buffer (500 lines), notifications coalesced
to ~4 Hz, and `verbose` **off by default** so per-packet `d()` lines are dropped
at the source. Added `dLazy(() => ...)` for hot paths so the message string is
not even built when verbose is off (used by the HR notify path). Entries are now
typed (`LogEntry`/`LogLevel`) instead of pre-formatted strings, so the console
colours by level without substring matching on `'[ERROR]'`.

### 2.8 Service-discovery cache

`discoverServices()` was called in **nine** separate helpers — `_handleConnected`,
`_syncTime`, `_setFitnessGoal`, `_subscribeToSteps`,
`_subscribeToMissingNotifications`, `_writeConfig`, `_setUserInfo`,
`_setupHeartRate`, `_readBattery` — i.e. ~9 full GATT round-trips per connect,
serialised through connect-time setup. Now discovered once per connection and
cached (`_discoverServicesCached`), with a `_findChar(service, char)` helper that
replaced five copies of the same nested lookup loop. The cache is cleared on
`connect()` and on `_handleDisconnect()`, so a reconnect can never hand out stale
characteristic handles from the previous connection's GATT database.

### 2.9 Debug console

`ListView.builder` over the bounded buffer with `reverse: true` (no reversed copy
per rebuild), a live line counter, and a verbose toggle in the app bar.

---

## 3. What is verified, and how

| Claim | Evidence |
|---|---|
| Burst of events → ≤1 trailing run | `test/performance_test.dart` — Coalescer group |
| Log buffer bounded, newest kept | BLELogger ring-buffer test |
| Verbose lines cost nothing when off | `dLazy` test asserts the closure never runs |
| Duplicate HR timestamps rejected without an O(n) rebuild | store dedup tests |
| Out-of-order backfill still ends sorted | store sort test |
| No-op add does **not** bump revision | revision test (a no-op must not invalidate memoised analyses) |
| `computeSleepDays` reused within a build, refreshed after a change | identity test |
| Live bpm doesn't disturb aggregates | `withCurrentBpm` test |
| Heart aggregate reused across beats | `AnalysisCache` test asserts `same(a.insights)` |
| Auth path untouched | `ecdh_b163_test` + `huami2021_chunked_test` still green |

**Not verified here:** actual on-device frame times. Queued as §P1 in
`pending-hardware-verification.md`.

---

## 4. Honest limits

- The 250 ms coalescing window is a judgement call, not a measured optimum. It
  is a named constant in `Coalescer` and easy to retune once a device profile
  exists.
- `AnalysisCache` holds one slot per analysis type. Today and Sleep share the
  sleep slot, so alternating between those two tabs recomputes each time. This
  is deliberate — a bigger cache costs memory for a case (rapid tab flipping)
  that is not the reported problem.
- Frame cost is now dominated by widget construction, not analysis. If profiling
  later shows the Today tab still janky at 1 Hz, the next step is
  `RepaintBoundary` placement and chart decimation (Phase 7), not more caching.
