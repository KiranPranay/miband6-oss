# findings-17 — Notifications: why nothing ever reached the band

**Date:** 2026-08-09
**Scope:** the whole notification path, native and Dart, plus the outbound wire
format. `flutter analyze` clean; `flutter test` 101/101 at commit time;
`flutter build apk --debug` succeeds (which is what validates the Kotlin).

> Not hardware-verified — no adb device this session. §P5 in
> `pending-hardware-verification.md` lists the eight checks that matter, of
> which **P5.2** (post-swipe delivery) is the one that proves the main fix.

---

## 1. What was NOT the bug

Worth recording, because it is the first thing everyone suspects.

Our `BandNotificationListener` manifest declaration is byte-for-byte equivalent
to Gadgetbridge's working one — same `BIND_NOTIFICATION_LISTENER_SERVICE`
permission, same intent-filter, **same `android:exported="false"`**
(`android/app/src/main/AndroidManifest.xml:74-82` vs
`gadgetbridge/app/src/main/AndroidManifest.xml:623-635`).

`exported="false"` does **not** stop the system binding a
`NotificationListenerService`; system_server is permission-exempt, and
Gadgetbridge ships exactly this and works. The manifest was fine.

---

## 2. Bug 1 — the native→Dart hop died with the activity

`NotificationBridge.channel` was assigned in exactly one place:
`MainActivity.configureFlutterEngine` (`MainActivity.kt:61`), on the **activity's
own** FlutterEngine.

`FlutterActivity` destroys that engine together with the activity by default.
After detach, `FlutterJNI.dispatchPlatformMessage` **drops the message with a
`Log.w`** rather than throwing. So the moment the activity was gone — swiped
away, OOM-killed, or never created because the system cold-bound the listener
after a reboot — `NotificationBridge.dispatch` became a `channel?.invokeMethod`
no-op with **no error, no log, no queue, no retry**.

That is the steady state for a band app, not an edge case: the entire point is
to run with no UI on screen. It was made worse by two things fixed in
findings-16: `_handleDisconnect` tore the foreground service down on every
disconnect, and `autoRunOnBoot` was false, so nothing restarted the engine.

### Fix

`BandApplication.kt` (new) creates a **process-lifetime FlutterEngine** at
`Application.onCreate`, caches it in `FlutterEngineCache`, and registers the
`band/notifications` channel on *that* engine.

`MainActivity` now *attaches to* the cached engine
(`provideFlutterEngine` + `shouldDestroyEngineWithHost() == false`) instead of
creating its own, so there is still exactly **one** Dart isolate and one BLE
connection — the activity simply comes and goes around it.

Belt and braces: `NotificationBridge` keeps a bounded 32-entry queue for the
window before the channel attaches, flushed on `attach()`, and `detach()` only
clears the reference it owns so an activity teardown can never drop the warm
engine's channel. Engine creation is wrapped in try/catch — if it ever fails the
app still runs with UI-only notifications, which is strictly better than not
starting.

## 3. Bug 2 — the payload was wrong in five ways

Re-derived from Gadgetbridge's legacy path (which is what MB6 uses:
`MiBand6Support → MiBand5Support → MiBand4Support → MiBand3Support →
AmazfitBipSupport → HuamiSupport`) and cross-checked against Notify.

Correct app notification, to `fee0/0x0020` via `writeToChunkedOld` type 0:

```
[0xFA][0x00 0x00 0x00 0x00][0x01][iconId]
  utf8(title)   0x00
  utf8(body)    0x00
  utf8(appName) 0x00
```

| # | Ours (before) | Correct |
|---|---|---|
| 1 | byte[5] = `0x00` | **`0x01`** |
| 2 | byte[6] = `0xFA`; the `icon:` argument was silently discarded | **a real Huami icon id** (generic = 11) |
| 3 | `"" \0 body \0 title \0` — swapped, app name never sent | **`title \0 body \0 appName \0`** |
| 4 | zero-padded to ≥18 bytes | **no padding** |
| 5 | one hard-coded `[00 C0 00]` frame, truncated at 230 B | **real chunking** |

On (5): `0xC0` is not a magic constant, it is `last|first`. It is only correct
for a single-frame message. Correct framing is
`[0x00][flags|type][count][payload]` with `0x80` last, `0x40` middle/consecutive,
`0x00` first-of-several, and chunk size
`min(512, max(23, mtu) - 3) - 3` — **17 bytes at MTU 23**, 241 at MTU 247. The
old code depended on `requestMtu(247)` having succeeded, which is best-effort;
we now record the **negotiated** MTU and chunk against it.

### Calls were on the wrong characteristic entirely

Mi Band 6 does **not** use `onSetCallStateNew` (that is wired only for
Bip3/BipS/GTS2/GTR2/ZeppE). It inherits
`HuamiSupport.onSetCallState → AmazfitBipTextNotificationStrategy`, which writes
to the **standard ANS NEW_ALERT characteristic `0x2A46`**:

```
[0x03][0x01] + utf8(caller)   → incoming call
[0x03][0x00]                  → dismiss
```

Our 10-byte `[03,0,0,0,0,0,0,0,0,3]` chunked frame could never have worked.
Notify does byte-for-byte the same as GB here (`y5/q.java w()`, `y5/a0.java`).

## 4. Bug 3 — chat notifications arrived blank and were dropped

`BandNotificationListener` read only `EXTRA_TITLE` + `EXTRA_TEXT`/`EXTRA_BIG_TEXT`.
Every major chat app (WhatsApp, Signal, Telegram, Messages) posts
`MessagingStyle`, where the message body lives in `EXTRA_MESSAGES` — so the text
came back empty and the notification was discarded as blank.

Now reads `EXTRA_MESSAGES` (via the documented Message-bundle keys `text` /
`sender`, which avoids both an androidx dependency and an API-level surprise)
and `EXTRA_TEXT_LINES`, falling back as before. `CATEGORY_CALL` is also let
through the ongoing-notification filter, since an incoming call is `FLAG_ONGOING`
and is the single most useful alert.

## 5. Bug 4 — the listener could stay unbound

Android unbinds notification listeners after app updates, low memory or a crash
and does not reliably rebind (Gadgetbridge runs a whole monitor service for
this). Added `onListenerDisconnected → requestRebind()`, plus a manual
`requestRebind` channel method.

## 6. Everything now logs its decision

The relay previously dropped notifications in three places with no trace. Every
outcome is now an explicit `RelayDecision` — `relayDisabled`, `appNotSelected`,
`bandNotReady`, `duplicate`, `screenOn`, `forwarded` — and is logged.

Deliberate choice: a notification arriving while the band is disconnected is
**dropped, not queued**. A notification delivered ten minutes late is noise.

## 7. Features added on top

- **Dedup** (30 s window on app+title+body): apps re-post constantly — typing
  indicators, progress, a second message in a thread — and each re-post
  previously buzzed the wrist again.
- **Privacy mode**: sends app + title only, never the body.
- **Skip while the screen is on**: don't buzz the wrist for something already on
  the phone.
- **Test alert**: writes straight to the band, bypassing Android entirely, so
  one tap tells you which half of the path is broken.
- **Per-app icons** from GB's `HuamiIcon` table; unknown apps get the generic
  glyph (11) rather than a plausible-but-wrong logo.

## 8. Verified here

`test/alert_manager_test.dart` (14 tests) pins the exact bytes: the 7-byte
header including `0x01` at [5] and the icon at [6], the three NUL-terminated
fields in the right order, a byte-for-byte match against the Gadgetbridge
worked example, the 230-byte cap, UTF-8-safe truncation (no split emoji), the
chunk-size formula, all four flag cases, and round-trip reassembly at three
chunk sizes.

Kotlin changes are validated by `flutter build apk --debug` succeeding.

## 9. Honest limits

- **Nothing here has touched a band.** The payload is derived from two
  independent references and pinned by tests, but Gate 8's visual confirmation
  is the only thing that proves the band renders it.
- The warm-engine change alters app startup (Dart `main()` now runs at process
  start). It builds and is guarded, but P5.2 is the real check.
- Notification **actions** (reply/dismiss from the band) are not implemented.
- The icon map covers ~30 common packages; everything else is the generic icon.
