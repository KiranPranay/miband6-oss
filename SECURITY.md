# Security policy

## Reporting a vulnerability

Please report security issues **privately**, not in the public issue tracker.

Use GitHub's [private vulnerability reporting](https://github.com/KiranPranay/miband/security/advisories/new)
(Security → Report a vulnerability), or contact the maintainer directly through
their GitHub profile.

Please include:

- What the issue is and what an attacker could achieve
- Steps to reproduce, or the relevant bytes / log lines
- Affected version or commit

This is a hobby project maintained in spare time. Expect an initial response
within about a week. There is no bounty programme.

---

## Scope

This app pairs with a BLE device and stores health data locally. The parts most
worth scrutiny:

| Area | Where |
|---|---|
| Auth key storage | `flutter_secure_storage` → Android Keystore (`lib/storage/secure_storage.dart`) |
| Sign-key / ECDH handshake | `lib/core/huami2021_auth.dart`, `lib/core/ecdh_b163.dart` |
| Legacy AES-ECB handshake | `lib/core/encryption.dart` |
| Chunked transport framing | `lib/core/huami2021_chunked.dart` |
| Notification content handling | `lib/core/notification_relay.dart`, `lib/core/alert_manager.dart` |
| Microphone / snoring detection | `lib/core/snore_detector.dart`, `lib/core/sleep_audio_controller.dart` |
| Local persistence | `lib/storage/activity_store.dart` |

### Especially interesting

- **Anything that lets a nearby device impersonate the band**, or a paired band
  reach beyond its own data.
- **Auth key exposure** — logs, backups, exported files, crash output. The key
  is the credential for the band; treat any leak as serious.
- **Notification relay leaking message content** when *Private alerts* is on.
  That switch is supposed to send only the app name and title.
- **Microphone audio escaping memory.** Snoring detection analyses audio in a
  rolling buffer; a path that writes audio to disk or off the device would be a
  serious bug, not a feature.

### Out of scope

- Physical access to an unlocked device.
- Attacks needing root on the phone.
- The Mi Band's own firmware — report those to Xiaomi/Zepp.
- The fact that BLE pairing needs a key extracted from the vendor app. That is
  a property of the ecosystem, not a flaw here.

---

## What this app does with your data

Stated so you can verify it rather than trust it:

- Health data is written to the app's private directory as JSON. It is not
  encrypted at rest beyond Android's own app sandboxing and full-disk
  encryption.
- **No health data is transmitted anywhere.** There is no account, no sync
  endpoint, no analytics, no crash reporting.
- The auth key is held in the Android Keystore via `flutter_secure_storage`,
  never in the JSON files and never in logs.
- Debug logging can include raw protocol bytes. It is **off by default**
  (`BLELogger.verbose`), and the Debug Console lives under Profile → Debug
  Console rather than on any main screen. If you share a log, read it first.
- Microphone audio is processed in memory and discarded. Only derived
  measurements — timestamps and loudness — are persisted.

Uninstalling removes everything.

---

## Note on the auth key

The 16-byte auth key is what proves to the band that you are its owner. Anyone
who has it, and is in Bluetooth range, can talk to your band.

- Do not paste it into issues, logs, or screenshots.
- It is stored in the Keystore, but an Android backup of a debuggable build can
  still expose app data — build release for daily use.
