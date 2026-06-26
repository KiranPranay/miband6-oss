# findings-10 — Sleep-audio (mic snoring) build notes + privacy model

**Date:** 2026-06-26
**Branch:** `sleep-audio`
**Scope:** opt-in, on-device overnight snoring/sleep-sound detection via the phone
microphone. The band exposes no snoring/respiration/temperature, so this is the
one legitimate *phone-derived* sleep metric. No BLE/auth/parser code is touched.

## Privacy model (the contract this feature is built to honour)

1. **Opt-in only, informed consent.** The mic is never auto-enabled. First use
   shows a consent screen stating plainly: the mic listens during a sleep
   session, audio is processed **on the device only**, **no audio is recorded to
   disk or uploaded anywhere**, and only snore-event *times + loudness* are kept.
   The user must actively accept.
2. **No audio persisted, no audio transmitted.** PCM frames from `record` are
   processed in memory and discarded. The code writes **no** WAV/PCM/any audio
   file and makes **no** network call on the audio path. There is no telemetry on
   audio. (Verification: grep for file writes / HTTP in the audio path — see
   "Verification" below.)
3. **Always-visible active indicator.** While listening, a dedicated foreground-
   service notification ("Listening for snoring — tap to stop") is shown, plus an
   in-app listening state. One tap stops.
4. **Bystander awareness.** Consent copy notes others in the room may be heard and
   suggests informing anyone sharing the space (even though no audio is stored).
5. **Graceful permission handling.** `RECORD_AUDIO` via `permission_handler`; if
   denied, a clear "microphone permission needed" state — never a crash, never
   nagging.
6. **Session-scoped.** The mic runs only inside an explicitly started session and
   stops on wake/stop. No background mic outside a started session.

## Android foreground-service design (why a separate service)

The existing BLE keep-alive uses `flutter_foreground_task`, whose service starts
with `FOREGROUND_SERVICE_TYPE_MANIFEST` — i.e. it claims **every** type in the
manifest. Adding `microphone` to that shared service would make *every* BLE
service-start (which happens on connect, before any mic opt-in) demand
`RECORD_AUDIO`, crashing on targetSdk 34+ (Android 14).

So sleep-audio uses a **dedicated native foreground service**
(`SleepAudioService.kt`, `foregroundServiceType="microphone"`) started only when a
session begins (after `RECORD_AUDIO` is granted) and stopped at session end. It
runs alongside the BLE service; the two are independent. The mic FGS keeps the
process alive so the main-isolate `record` stream survives screen-off; its
notification is the always-visible indicator. **No BLE code changes.**

## Capture + detection (summary; full detail in docs/sleep-audio.md)

- `record` PCM16 stream, mono, low sample rate (snore energy is low/mid-freq, so
  full 44.1 kHz is unnecessary — saves battery). Processed in short windows.
- Per window: RMS amplitude + a low/mid band-energy proxy. Adaptive noise floor
  from the session's quiet periods (no hardcoded dB). A snore *event* = a
  sustained run of elevated low-band windows (duration + amplitude gated) so a
  one-off clap/voice isn't logged.
- Stored per event: start, duration, peak/mean intensity. Aggregated: total snore
  minutes, count, loudest periods, timeline. **"Sound consistent with snoring,"
  not a medical claim.**

## Verification (Pixel 9a) — PASSED

- [x] Foreground capture works: 3 s windows with real, varying RMS
      (-40 → -36 dBFS); 0 events in a quiet room.
- [x] Mic FGS confirmed: `SleepAudioService foregroundId=2002 types=0x00000080`
      (microphone), running alongside the BLE service.
- [x] **Survives screen-off** — windows kept flowing with the display off.
- [x] **Clean stop** — mic service + notification gone after stop (no orphan).
- [x] **No audio persisted** — `find` for `*.wav/*.pcm/*.aac/*.m4a/*.raw` in the
      app sandbox returned nothing; only `snore_sessions.json` (event
      times + loudness) is written.
- [x] **No network on the audio path** — the audio files import no
      HttpClient/Socket/WebSocket/http; only `dart:io` File for the JSON events.
- [x] Detection unit test green (`test/snore_detector_test.dart`, 9 cases incl.
      single-clap-not-an-event); `flutter analyze` clean; full `flutter test`
      green.
- [x] **Live detection end-to-end** — injected a sustained low-pass test sound;
      the mic responded (RMS -40 → -29 dBFS), the detector logged **1 episode
      (~1 min)**, and the Sleep screen showed "Snoring · from phone microphone ·
      1 min · 1 episode" with a timeline. The persisted `snore_sessions.json`
      held only event times + loudness (`s/e/p/m`), **no audio**.
- [!] **Calibration finding:** the first run showed the band-ratio of *loud*
      sound arriving *lower* than quiet ambient (laptop-speaker bass roll-off),
      so the original 0.55 band gate was too strict (it would reject real
      snoring). Relaxed to a light 0.30 gate — v1 leans on amplitude + duration;
      distinguishing snoring from sustained speech is a documented limitation.
