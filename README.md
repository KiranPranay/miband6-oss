# Mi Band 6 — open Flutter companion app

An independent Android companion for the **Xiaomi Mi Band 6**, built on a
reverse-engineered protocol. No Xiaomi account, no cloud sync, no telemetry —
your data stays on your phone.

The protocol was reconstructed from the **Gadgetbridge** source (clean-room
reference) cross-checked against the decompiled **Notify** (`com.mc.miband1`)
and **Mi Fit** APKs, then confirmed against the physical band. The authoritative
spec lives in [`docs/reverse-engineering/protocol-mb6.md`](docs/reverse-engineering/protocol-mb6.md).

> **Status: working, partially verified.** The auth + heart-rate + activity path
> is confirmed on real hardware (all gates pass, see `test-results-01.md`).
> Everything added since is unit-tested and analyzer-clean but **not yet
> hardware-verified** — the open list is
> [`pending-hardware-verification.md`](docs/reverse-engineering/pending-hardware-verification.md).
> This README marks each feature accordingly.

---

## Features

| Feature | Status |
|---|---|
| Sign-key (ECDH) authentication | ✅ hardware-verified |
| Realtime heart rate + history | ✅ hardware-verified |
| Steps / distance / calories | ✅ hardware-verified |
| Battery | ✅ hardware-verified |
| SpO2 history | ✅ hardware-verified |
| Sleep sessions, stages, efficiency | ⚠️ rebuilt, unit-tested, **accuracy unverified** |
| Band settings (HR interval, display, goals, DND…) | ⚠️ implemented, **unverified on band** |
| Notifications → band | ⚠️ rewritten end-to-end, **unverified on band** |
| Native stress (all-day + manual) | ⚠️ implemented, **unverified on band** |
| Background connection + auto-reconnect | ⚠️ implemented, **unverified on band** |
| Overnight snoring detection (phone mic, on-device) | ✅ hardware-verified |
| Light + dark theme | ⚠️ contrast-tested, **never seen on a device** |
| HRV / recovery | ❌ **not possible** — this firmware sends no RR intervals |

### What this app deliberately does **not** show

A health app that invents numbers is worse than one that shows fewer. Omitted
on purpose, each with a reason:

- **REM sleep** — the firmware never populates the REM byte.
- **HRV / recovery** — needs beat-to-beat intervals; all 34 captured heart-rate
  notifications are 2 bytes with the RR flag clear.
- **Floors climbed** — no altimeter on this band.
- **Hydration** — no sensor; it would be a manual log pretending to be a metric.
- **SpO2 all-day monitoring / sleep-breathing quality toggles** — ZeppOS-only
  settings that this band's protocol has no equivalent for.

---

## Setup

### Requirements

- Flutter 3.44+, Android device (API 21+; the background service targets 13+)
- A **JDK with a compiler**. If Gradle reports
  `Toolchain installation … does not provide the required capabilities: [JAVA_COMPILER]`,
  your default `java` is a JRE. Build with, e.g.:
  ```bash
  export JAVA_HOME=/opt/android-studio/jbr
  flutter build apk --debug
  ```

### Build and run

```bash
flutter pub get
flutter analyze          # expected: no issues
flutter test             # expected: all green
flutter run              # or: flutter build apk --debug
```

### Pairing

1. **Unpair the band from Zepp Life / Mi Fit first** — a Mi Band only talks to
   one host at a time.
2. Get your 16-byte **auth key** (see below) and enter it in
   Settings → Authentication → Auth Key.
3. Settings → Device → Scan & Connect, pick the band.

The app then remembers the band and reconnects on its own — including after a
reboot — until you explicitly disconnect.

### Extracting the auth key

The band will only authenticate with the key it was paired with. Common routes:

- **From Zepp Life on Android**: pair in Zepp Life, then read the key from the
  app's local database (`origin_db` / `devicelist` table) with root or an ADB
  backup, or use one of the community key-extractor tools.
- **From a Xiaomi/Zepp account export**: the token is included in the device
  record returned by the account API at pairing time.

Enter it as 32 hexadecimal characters. It is stored with
`flutter_secure_storage` (Android Keystore) and never leaves the device.

### Permissions, and why each is needed

| Permission | Why |
|---|---|
| `BLUETOOTH_SCAN` / `BLUETOOTH_CONNECT` | find and talk to the band |
| `ACCESS_FINE_LOCATION` | Android requires it for BLE scanning |
| `FOREGROUND_SERVICE` + `…_CONNECTED_DEVICE` | keep the BLE link alive with the screen off |
| `POST_NOTIFICATIONS` | show the persistent connection notification (Android 13+) |
| `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | asked **once, with an explanation** — Doze otherwise suspends the link overnight, exactly when sleep tracking runs. Declining is fine; the app degrades to foreground-only |
| `RECEIVE_BOOT_COMPLETED` | reconnect after a phone reboot without opening the app |
| Notification access (special) | read notifications to forward them to the band |
| `RECORD_AUDIO` + `…_MICROPHONE` | **opt-in only**, for overnight snoring detection. Audio is analysed in memory and never written to disk or transmitted |

---

## Screenshots

_Placeholders — to be captured on device (queued as P7.1 alongside the dark-mode
device pass)._

| Today | Sleep | Heart | Activity |
|---|---|---|---|
| `docs/screenshots/today.png` | `docs/screenshots/sleep.png` | `docs/screenshots/heart.png` | `docs/screenshots/activity.png` |

| Stress | Band settings | Notifications | Dark mode |
|---|---|---|---|
| `docs/screenshots/stress.png` | `docs/screenshots/band-settings.png` | `docs/screenshots/notifications.png` | `docs/screenshots/dark.png` |

---

## Project layout

```
lib/core/       protocol + analysis engines (pure, unit-tested)
  ble_manager.dart          connection, auth, characteristics
    ├── huami2021_auth.dart     sign-key (ECDH) handshake
    ├── connection_supervisor.dart  backoff, adapter, liveness
    └── hardware_test_session.dart  gated on-device test runner
  activity_fetcher.dart     activity / SpO2 / stress fetch
  sleep_analyzer.dart       session detection + staging
  stress_analyzer.dart      band stress + HRV maths + honest fallback
  band_config.dart          every band setting, as bytes
  alert_manager.dart        notification wire format
lib/ui/         screens and design tokens
android/…/kotlin/  notification listener + warm FlutterEngine
docs/reverse-engineering/   protocol spec, findings, verification
```

## Documentation

- [`00-INDEX.md`](docs/reverse-engineering/00-INDEX.md) — status and iteration log
- [`protocol-mb6.md`](docs/reverse-engineering/protocol-mb6.md) — **authoritative** spec
- [`diff-our-vs-correct.md`](docs/reverse-engineering/diff-our-vs-correct.md) — living correction table
- [`pending-hardware-verification.md`](docs/reverse-engineering/pending-hardware-verification.md) — what is **not** yet verified
- [`hardware-test-session.md`](docs/reverse-engineering/hardware-test-session.md) — the gated on-device runner
- [`ui-ux-review.md`](docs/ui-ux-review.md) — design decisions and open items

## Contributing

Two rules matter more than style:

1. **Every byte written to the band needs a source** — a Gadgetbridge
   file/class or a decompiled reference — recorded in `protocol-mb6.md`
   *before* the first hardware write.
2. **Never claim a measurement you cannot make.** If the data is not there, omit
   the metric and say why.

Run `flutter analyze` and `flutter test` before committing; add a hardware gate
for anything that touches the band.

## Credits & licence

Protocol knowledge derives from [Gadgetbridge](https://gadgetbridge.org/)
(AGPL-3.0). This is an independent project, not affiliated with or endorsed by
Xiaomi, Huami/Zepp, or the Gadgetbridge project.
