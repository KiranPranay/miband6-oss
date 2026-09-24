# Findings 27 — Calls: the band was driven by the wrong signal

2026-09-24. Reported after a day of real calls: the band buzzed and showed the
caller with Silence and Decline, but neither button did anything; the band
also buzzed when the user *placed* a call; and it kept buzzing in the middle
of a call — on hold, on every refresh.

## What the code did

`BandNotificationListener` let `CATEGORY_CALL` notifications through the
ongoing-notification filter, flagged them `isCall`, and `NotificationRelay`
wrote the ANS incoming-call alert (`03 01 <caller>`, §8.3) for **every one of
them**. `onNotificationRemoved` for the same category wrote `03 00`.

That treats the dialer's notification as if it were the call. It is not:

| The notification… | …so the band |
|---|---|
| is posted for an outgoing call too (title = callee, text "Calling…") | buzzed when the user dialled |
| is re-posted on every call-timer tick, on hold, on speaker/Bluetooth route change | buzzed mid-conversation, again and again |
| carries no ringing-vs-active distinction | showed *Silence / Decline* for a call already in progress |
| was re-sent between the user's press and the band's event | had its screen replaced under the button that was pressed |

The dedup table in the relay (`dedupWindow` 30 s) was bypassed for calls on
purpose — "a user who is being rung wants to know" — which removed the one
thing that would have limited the damage.

## What the references do

All three derive call state from **telephony**, and none from a notification:

- **Gadgetbridge** `externalevents/PhoneCallReceiver.java` — `PHONE_STATE`
  broadcast → `onCallStateChanged(state, number)`; same state twice is
  ignored; `RINGING` → `CALL_INCOMING`; `OFFHOOK` after `RINGING` →
  `CALL_START`, otherwise `CALL_OUTGOING`; `IDLE` → `CALL_END`.
  `HuamiSupport.onSetCallState` (`:1222-1238`) alerts only on `CALL_INCOMING`
  and stops on `CALL_START` / `CALL_END`. Outgoing calls never reach the band.
- **Mi Fit** `com.xiaomi.hm.health.receiver.PhoneStateReceiver` — the same
  broadcast; `EXTRA_STATE_RINGING` schedules the alert after the user's
  "incoming call delay" (`HMMiliConfig.getInComingCallNotifyTime`),
  `OFFHOOK` and `IDLE` stop it.
- **Notify** `i9/j.java` class `q extends PhoneStateListener` — the three
  states; nothing keyed on notifications.

## Why Silence did nothing

`CallControlHost.silenceRinger` tried `TelecomManager.silenceRinger()` — which
needs `MODIFY_PHONE_STATE`, a signature permission — then
`AudioManager.adjustStreamVolume(STREAM_RING, ADJUST_MUTE)`. Since Android N,
muting the ring stream far enough to change the ringer mode throws
`SecurityException: Not allowed to change Do Not Disturb state` unless the app
holds Notification Policy access. Both throws were caught and turned into
`false`; the band's press was logged as "could not silence the ringer" and
nothing else happened.

The references all switch the **ringer mode** to silent for the duration of
the call and put it back afterwards — Gadgetbridge's `MUTE_CALL` branch (saves
`getRingerMode()`, `RINGER_MODE_SILENT`, restore on `IDLE`), Notify's
`i9/j.java G()` (`setRingerMode(0)` with a 90 s fallback restore), Mi Fit's
`IncomingCallAlertActivity`. That path needs Do Not Disturb access, which is a
user grant on a system settings page, and every one of them asks for it.

## Why Decline did nothing — not yet explained

`0x07` → `TelecomManager.endCall()` is exactly Gadgetbridge's path
(`GBCallControlReceiver.handleCallCmdTelecomManager`), `ANSWER_PHONE_CALLS` is
granted, and the channel is registered on the process-lifetime engine. Two
possibilities remain: the event never reached the phone, or it arrived while
the relay was re-sending the alert and the band's screen had just been
replaced. The logs from those calls are gone (in-memory ring buffer, app
restarted since). Probe P12.4 settles it with one live call and `logcat`.

## The fix

- `CallStateHost.kt` registers a `TelephonyCallback.CallStateListener` (API
  31+, `PhoneStateListener` below) on the process-lifetime engine and reports
  transitions — `ringing`, `answered`, `outgoing`, `ended` — on
  `band/call_state`, with Gadgetbridge's exact derivation and duplicate
  suppression. It also owns Silence: ringer mode → silent while ringing,
  restored on `IDLE`; returns false without DND access.
- `CallSession` (Dart, pure, tested with a fake clock) alerts the band once
  per `ringing`, clears on `answered` / `ended`, does nothing for `outgoing`.
  The dialer's notification only lends the caller's name and number; a
  700 ms grace waits for it, or it is used at once if it arrived first. Every
  later post of that notification is ignored.
- `NotificationRelay` hands `CATEGORY_CALL` notifications to the session
  (`RelayDecision.callRouted`) and no longer writes call alerts itself.
  `onNotificationRemoved` no longer drives the band.
- Settings › Band buttons gains *Silence from the band*, which opens the Do
  Not Disturb access page and shows whether it is granted. Phone permissions
  now also count `READ_PHONE_STATE`, without which no call reaches the band.

## What this does not fix

- Vibration on the phone may continue after Silence: Telecom decides whether
  to vibrate when ringing starts and does not re-check the ringer mode. The
  references live with it. P12.5.
- The band's own reply-with-text button (§13) is unchanged: unverified, off.
