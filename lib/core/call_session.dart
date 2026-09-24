import 'dart:async';

import 'logger.dart';

/// What the phone's telephony reports, one transition at a time
/// (`CallStateHost.kt`). Mirrors Gadgetbridge's `CallSpec` commands.
enum PhoneCallEvent {
  /// IDLE → RINGING. The only event that alerts the band.
  ringing,

  /// RINGING → OFFHOOK. Picked up on the phone: clear the band's screen.
  answered,

  /// IDLE → OFFHOOK. A call the user placed. Nothing for the band.
  outgoing,

  /// → IDLE. Over, whichever way: clear the band's screen.
  ended;

  static PhoneCallEvent? parse(String s) {
    for (final e in values) {
      if (e.name == s) return e;
    }
    return null;
  }
}

enum CallPhase { idle, ringing, active, outgoing }

/// The two things the band can do about a call.
abstract class CallSink {
  /// Connected and authenticated.
  bool get ready;

  /// ANS `03 01 <caller>` — the band's call screen with Silence and Decline.
  Future<void> showIncoming(String caller);

  /// ANS `03 00` — take the call screen down.
  Future<void> clear();
}

/// Decides when the band hears about a call, and says it once.
///
/// The previous design sent the band an "incoming call" for every
/// CATEGORY_CALL notification the dialer posted. Dialers re-post that
/// notification constantly — the call timer ticks, a call goes on hold, the
/// audio route changes — and they post it for outgoing calls too. So the band
/// buzzed when you dialled, buzzed again mid-conversation, and its Decline and
/// Silence buttons were pressed against a screen that had just been replaced.
///
/// Here telephony state is the only thing that moves the machine
/// ([onPhoneEvent]); the dialer's notification only lends the caller's name
/// ([onCallNotification]), because on modern Android the telephony callback
/// carries no number. The alert goes out exactly once per ringing call:
/// immediately when the name is already known, otherwise after a short grace
/// so the notification can supply it — and never again for that call,
/// whatever the notification does afterwards.
class CallSession {
  CallSession({
    required CallSink sink,
    required BLELogger logger,
    this.nameGrace = const Duration(milliseconds: 700),
    this.notificationLookback = const Duration(milliseconds: 1500),
  })  : _sink = sink,
        _logger = logger;

  final CallSink _sink;
  final BLELogger _logger;

  /// How long to wait for the dialer's notification to name the caller before
  /// alerting with a generic label.
  final Duration nameGrace;

  /// A call notification seen this recently *before* RINGING counts as this
  /// call's — the two arrive within milliseconds of each other, in either
  /// order.
  final Duration notificationLookback;

  CallPhase phase = CallPhase.idle;

  /// Caller as the dialer named them (contact name, else number).
  String? callerLabel;

  /// Digits found in the dialer's notification, kept until the next ringing
  /// call so decline-with-text can still use it after the call ends.
  String? callerNumber;

  /// True while the band is showing this call.
  bool shownOnBand = false;

  /// How many call alerts have gone to the band. Diagnostics and tests.
  int alertsSent = 0;

  Timer? _grace;
  String? _recentLabel;
  String? _recentNumber;
  DateTime? _recentAt;

  DateTime Function() now = DateTime.now;

  void onPhoneEvent(PhoneCallEvent e) {
    switch (e) {
      case PhoneCallEvent.ringing:
        if (phase == CallPhase.ringing) return; // duplicate report
        phase = CallPhase.ringing;
        shownOnBand = false;
        callerLabel = null;
        callerNumber = null;
        // A notification that arrived a moment *before* telephony did belongs
        // to this call; use it and skip the wait.
        final at = _recentAt;
        if (at != null && now().difference(at) <= notificationLookback) {
          callerLabel = _recentLabel;
          callerNumber = _recentNumber;
          _forgetRecent();
          _show();
        } else {
          _grace?.cancel();
          _grace = Timer(nameGrace, _show);
        }
        break;

      case PhoneCallEvent.answered:
        _grace?.cancel();
        phase = CallPhase.active;
        _clearIfShown('answered on the phone');
        break;

      case PhoneCallEvent.outgoing:
        _grace?.cancel();
        phase = CallPhase.outgoing;
        _clearIfShown('outgoing call');
        _logger.i('Call: outgoing — nothing for the band');
        break;

      case PhoneCallEvent.ended:
        _grace?.cancel();
        phase = CallPhase.idle;
        _clearIfShown('call ended');
        break;
    }
  }

  /// The dialer's CATEGORY_CALL notification. Supplies the caller's name and
  /// number; never alerts on its own.
  void onCallNotification({required String title, required String text}) {
    final number = extractNumber(title) ?? extractNumber(text);
    final label = title.trim().isNotEmpty ? title.trim() : number;

    switch (phase) {
      case CallPhase.ringing:
        if (label != null) callerLabel ??= label;
        if (number != null) callerNumber ??= number;
        if (!shownOnBand &&
            _grace != null &&
            _grace!.isActive &&
            callerLabel != null) {
          _grace!.cancel();
          _show();
        }
        break;
      case CallPhase.idle:
        // Possibly the leading edge of a call telephony has not reported yet.
        _recentLabel = label;
        _recentNumber = number;
        _recentAt = now();
        break;
      case CallPhase.active:
      case CallPhase.outgoing:
        // Timer ticks, hold, audio route — the band does not care.
        break;
    }
  }

  void _show() {
    _grace = null;
    if (phase != CallPhase.ringing || shownOnBand) return;
    final label = callerLabel ?? 'Incoming call';
    if (!_sink.ready) {
      _logger.i('Call: ringing from "$label" but the band is not connected');
      return;
    }
    shownOnBand = true;
    alertsSent++;
    _logger.i('Call: ringing from "$label"'
        '${callerNumber != null ? ' (number captured)' : ' (no number)'} — alerting the band');
    _sink.showIncoming(label);
  }

  void _clearIfShown(String why) {
    if (!shownOnBand) return;
    shownOnBand = false;
    if (!_sink.ready) return;
    _logger.i('Call: $why — clearing the band');
    _sink.clear();
  }

  void _forgetRecent() {
    _recentLabel = null;
    _recentNumber = null;
    _recentAt = null;
  }

  void dispose() {
    _grace?.cancel();
    _grace = null;
  }

  /// First run of 7+ digits (with the usual separators) in [s].
  static String? extractNumber(String s) {
    final m = RegExp(r'\+?[0-9][0-9 \-()]{6,}[0-9]').firstMatch(s);
    if (m == null) return null;
    final digits = m.group(0)!.replaceAll(RegExp(r'[^0-9+]'), '');
    return digits.length >= 7 ? digits : null;
  }
}
