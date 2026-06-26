# Sleep-audio: on-device snoring detection (phone microphone)

Opt-in, privacy-first overnight snoring detection. The Mi Band 6 exposes no
snoring/respiration/temperature, so this is the one legitimate *phone-derived*
sleep metric. It is built so that **no audio ever leaves the device and no audio
is ever persisted** — only derived events (times + loudness) are stored.

## Privacy model (the guarantee)

- **Opt-in, informed consent.** Never auto-enabled. First use shows a consent
  screen stating: the mic listens during a session, audio is processed on-device
  only, no audio is recorded to disk or uploaded, only snore event times +
  loudness are stored, others in the room may be heard, and this is not a medical
  device. The user must actively accept (persisted as `sleep_audio_consent_v1`).
- **No audio persisted, no audio transmitted.** The `record` PCM stream is
  reduced to per-window energy features in memory and discarded. The code writes
  **no** audio file and makes **no** network call on the audio path. No telemetry.
- **Always-visible indicator.** A dedicated microphone foreground service
  (`SleepAudioService`, type `microphone`) shows an ongoing "Listening for
  snoring — tap to stop" notification the entire time, with a one-tap Stop.
- **Session-scoped.** The mic runs only inside an explicitly started session and
  stops on wake/stop. No background mic outside a session.
- **Graceful permissions.** `RECORD_AUDIO` via `permission_handler`; if denied, a
  clear "microphone permission needed" state with an Open-settings action.

### Why a separate foreground service
The BLE keep-alive uses `flutter_foreground_task`, which starts with
`FOREGROUND_SERVICE_TYPE_MANIFEST` (it claims every type declared in the
manifest). Putting `microphone` on that shared service would make every BLE
service-start demand `RECORD_AUDIO`, crashing on Android 14+ before the user ever
opts in. So sleep-audio uses its own native `SleepAudioService` (type
`microphone`), started only after consent + permission. The two foreground
services run independently; **no BLE code is touched.**

## Capture

- Package: `record` (PCM amplitude stream). `RecordConfig(encoder: pcm16bits,
  sampleRate: 8000, numChannels: 1)`.
- **Sample rate 8 kHz mono:** snoring energy is low/mid-frequency (fundamental
  ~tens–hundreds of Hz); 8 kHz (Nyquist 4 kHz) captures the relevant band while
  using ~1/5 the data of 44.1 kHz, saving battery and CPU. Mono is sufficient.
- Capture is continuous at this low rate (not 44.1 kHz "full-rate"), processed in
  **3-second windows**. Continuous-at-low-rate was chosen over duty-cycling so
  total snore minutes are measured directly rather than extrapolated from samples;
  duty-cycling is noted as a future battery optimization.

## Detection (on-device, lightweight — `SnoreDetector`)

Per 3 s window, the controller computes two cheap features from the PCM (no FFT):

- **RMS energy** → dBFS.
- **Low/total band-energy ratio:** a one-pole low-pass (~500 Hz cut at 8 kHz,
  α≈0.28) gives a low-band RMS; the ratio to total RMS is high for low-frequency
  snoring and lower for broadband voices/TV.

`SnoreDetector` then, per window `(rmsDb, bandRatio)`:

- Maintains an **adaptive noise floor** (EMA over quiet windows) — so a silent and
  a noisy room both work; there is **no hardcoded dB threshold**.
- A window is snore-like if `rmsDb > floor + 10 dB` **and** `bandRatio ≥ 0.30`.
  The **primary** discriminators are amplitude (above the floor) and **duration**;
  the band-ratio gate is deliberately light (drops only clearly high-frequency
  hiss/static).
- A **snore event** = a run of ≥ 3 consecutive snore-like windows (≥ 9 s),
  tolerating one sub-threshold gap window mid-episode. So a single clap (1 window)
  is **not** logged.
- Per event it stores start, end, peak and mean loudness (0..1 above floor).

Tunables (`SnoreConfig`): window 3 s, min 3 windows, max gap 1 window, floor
margin 10 dB, min band ratio 0.30, floor adapt rate 0.03. Covered by
`test/snore_detector_test.dart` (sustained run → event; single clap → none;
high-frequency hiss → none; adaptive floor in a noisy room; gap tolerance;
multiple episodes; summary aggregation).

**Calibration note / known limitation.** The received snore spectrum varies a lot
with the room and microphone. A hardware run (playing low-passed test audio
through a laptop speaker) showed the band-ratio of *loud* sound arriving lower
than quiet ambient — speaker/mic colouration — so an aggressive band gate would
reject real snoring. v1 therefore leans on amplitude + duration and keeps the
band gate light. Distinguishing snoring from *sustained* speech is consequently a
known v1 limitation (a single clap/short noise is still rejected by the duration
gate). Tightening this would need calibration against real labelled snoring
audio.

> This detects **sound consistent with snoring** — it is **not** a medical
> diagnosis. No apnea/medical claims are made anywhere.

## Data stored (`SnoreStore` → `snore_sessions.json`)

Only derived data, never audio:

```
SnoreSession { start, end, events: [ { start, end, peak, mean } ] }
```

Aggregated for the UI (`SnoreSummary`): total snore minutes, episode count,
loudest episode. The last ~30 sessions are kept.

## UI

- **Profile → Sleep sounds** and a **Sleep screen "Sleep sounds" card**.
- Empty state: an opt-in card ("Track snoring with your phone — on-device and
  private"). No fake numbers when unused.
- Active: a listening screen (pulsing mic, live event/minute counters, Stop).
- Result: "Snoring · from phone microphone" with total minutes, episode count and
  an event timeline across the night (or "No snoring detected").

## Battery & robustness

- Low sample rate + light per-window math (RMS + one-pole filter, no FFT).
- The microphone foreground service keeps the process alive through screen-off and
  app backgrounding (verified: windows keep flowing with the screen off). Stop is
  idempotent and fully releases the mic (verified: no orphan service/notification).
- **OEM caveat:** aggressive battery optimizers (Xiaomi/Oppo/Samsung etc.) may
  still kill background services overnight. If sessions end early, exempt the app
  from battery optimization in system settings.

## Hardware verification (Pixel 9a, Android, MB6 connected)

- Capture live: 3 s windows with real, varying RMS (-40 → -36 dBFS), 0 events in a
  quiet room.
- Mic FGS confirmed: `SleepAudioService foregroundId=2002 types=0x00000080`
  (microphone), alongside the BLE service.
- **Survives screen-off:** windows kept flowing with the display off.
- **Clean stop:** mic service/notification gone after stop.
- **No audio persisted:** `find` for `*.wav/*.pcm/*.aac/*.m4a/*.raw` in the app
  sandbox returned nothing.
- **No network on the audio path:** the audio files import no `dart:io`
  HttpClient/Socket and no `http` package (grep-verified).
- `flutter analyze` clean; `flutter test` green (incl. the detection suite).
