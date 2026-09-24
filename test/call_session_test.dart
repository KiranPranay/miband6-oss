import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:band/core/call_session.dart';
import 'package:band/core/logger.dart';

/// The band must hear about an incoming call exactly once, hear nothing about
/// a call the user placed, and have its screen cleared when the call is
/// answered or ends — whatever the dialer's notification does meanwhile.
/// These pin that against the three failures seen on the phone: buzzing on
/// outgoing calls, buzzing again on every notification refresh mid-call, and
/// buttons pressed against a screen that had just been replaced.
class _FakeBand implements CallSink {
  @override
  bool ready = true;
  final shown = <String>[];
  int clears = 0;

  @override
  Future<void> showIncoming(String caller) async => shown.add(caller);

  @override
  Future<void> clear() async => clears++;
}

void main() {
  late _FakeBand band;
  late CallSession s;

  setUp(() {
    band = _FakeBand();
    s = CallSession(sink: band, logger: BLELogger());
  });

  test('ringing alerts once, after the grace, with a generic label', () {
    fakeAsync((a) {
      s.now = () => a.getClock(DateTime(2026, 9, 24, 10)).now();
      s.onPhoneEvent(PhoneCallEvent.ringing);
      expect(band.shown, isEmpty,
          reason: 'waits for the dialer to name the caller');
      a.elapse(const Duration(milliseconds: 800));
      expect(band.shown, ['Incoming call']);
      expect(s.phase, CallPhase.ringing);
      expect(s.shownOnBand, isTrue);
    });
  });

  test('the notification names the caller and cuts the wait short', () {
    fakeAsync((a) {
      s.now = () => a.getClock(DateTime(2026, 9, 24, 10)).now();
      s.onPhoneEvent(PhoneCallEvent.ringing);
      a.elapse(const Duration(milliseconds: 100));
      s.onCallNotification(title: 'Alice', text: 'Mobile · Incoming call');
      expect(band.shown, ['Alice']);
      // Every re-post of that notification while ringing is ignored.
      s.onCallNotification(title: 'Alice', text: 'Incoming call');
      s.onCallNotification(title: 'Alice', text: '0:03');
      a.elapse(const Duration(seconds: 2));
      expect(band.shown, ['Alice']);
      expect(s.alertsSent, 1);
    });
  });

  test('a notification that beats telephony still names the caller', () {
    fakeAsync((a) {
      s.now = () => a.getClock(DateTime(2026, 9, 24, 10)).now();
      s.onCallNotification(title: '+91 98765 43210', text: 'Incoming call');
      a.elapse(const Duration(milliseconds: 50));
      s.onPhoneEvent(PhoneCallEvent.ringing);
      expect(band.shown, ['+91 98765 43210'], reason: 'no grace needed');
      expect(s.callerNumber, '+919876543210');
    });
  });

  test('a stale notification is not mistaken for a new call', () {
    fakeAsync((a) {
      s.now = () => a.getClock(DateTime(2026, 9, 24, 10)).now();
      s.onCallNotification(title: 'Bob', text: 'Incoming call');
      a.elapse(const Duration(seconds: 10));
      s.onPhoneEvent(PhoneCallEvent.ringing);
      a.elapse(const Duration(seconds: 1));
      expect(band.shown, ['Incoming call']);
    });
  });

  test('answering clears the band; later refreshes do nothing', () {
    fakeAsync((a) {
      s.now = () => a.getClock(DateTime(2026, 9, 24, 10)).now();
      s.onPhoneEvent(PhoneCallEvent.ringing);
      s.onCallNotification(title: 'Alice', text: 'Incoming call');
      s.onPhoneEvent(PhoneCallEvent.answered);
      expect(band.clears, 1);
      expect(s.phase, CallPhase.active);
      // The call timer, hold, speaker: all re-posts of the same notification.
      for (var i = 0; i < 30; i++) {
        s.onCallNotification(
            title: 'Alice', text: '0:${i.toString().padLeft(2, '0')}');
      }
      s.onCallNotification(title: 'Alice', text: 'On hold');
      a.elapse(const Duration(minutes: 1));
      expect(band.shown, ['Alice']);
      expect(band.clears, 1);
      s.onPhoneEvent(PhoneCallEvent.ended);
      expect(band.clears, 1, reason: 'nothing was showing');
      expect(s.phase, CallPhase.idle);
    });
  });

  test('an outgoing call never reaches the band', () {
    fakeAsync((a) {
      s.now = () => a.getClock(DateTime(2026, 9, 24, 10)).now();
      s.onPhoneEvent(PhoneCallEvent.outgoing);
      // The dialer's ongoing-call notification, posted and refreshed.
      s.onCallNotification(title: 'Carol', text: 'Calling…');
      s.onCallNotification(title: 'Carol', text: '0:01');
      a.elapse(const Duration(seconds: 5));
      s.onPhoneEvent(PhoneCallEvent.ended);
      expect(band.shown, isEmpty);
      expect(band.clears, 0);
    });
  });

  test('a missed or declined call clears the band once', () {
    fakeAsync((a) {
      s.now = () => a.getClock(DateTime(2026, 9, 24, 10)).now();
      s.onPhoneEvent(PhoneCallEvent.ringing);
      s.onCallNotification(title: 'Alice', text: 'Incoming call');
      s.onPhoneEvent(PhoneCallEvent.ended);
      expect(band.clears, 1);
      expect(s.shownOnBand, isFalse);
      expect(s.callerNumber, isNull);
    });
  });

  test('the number survives the end of the call for decline-with-text', () {
    fakeAsync((a) {
      s.now = () => a.getClock(DateTime(2026, 9, 24, 10)).now();
      s.onPhoneEvent(PhoneCallEvent.ringing);
      s.onCallNotification(title: 'Alice', text: '+91 98765 43210 · Mobile');
      expect(s.callerNumber, '+919876543210');
      s.onPhoneEvent(PhoneCallEvent.ended);
      expect(s.callerNumber, '+919876543210',
          reason: 'endCall() resolves after telephony reports IDLE');
      s.onPhoneEvent(PhoneCallEvent.ringing);
      expect(s.callerNumber, isNull, reason: 'a new call starts clean');
    });
  });

  test('a duplicate ringing report is not a second alert', () {
    fakeAsync((a) {
      s.now = () => a.getClock(DateTime(2026, 9, 24, 10)).now();
      s.onPhoneEvent(PhoneCallEvent.ringing);
      s.onCallNotification(title: 'Alice', text: 'Incoming call');
      s.onPhoneEvent(PhoneCallEvent.ringing);
      a.elapse(const Duration(seconds: 1));
      expect(band.shown, ['Alice']);
    });
  });

  test('a band that is not connected is left alone, and nothing is cleared',
      () {
    fakeAsync((a) {
      s.now = () => a.getClock(DateTime(2026, 9, 24, 10)).now();
      band.ready = false;
      s.onPhoneEvent(PhoneCallEvent.ringing);
      s.onCallNotification(title: 'Alice', text: 'Incoming call');
      s.onPhoneEvent(PhoneCallEvent.ended);
      expect(band.shown, isEmpty);
      expect(band.clears, 0);
    });
  });

  test('call waiting: ringing during an active call alerts, answering clears',
      () {
    fakeAsync((a) {
      s.now = () => a.getClock(DateTime(2026, 9, 24, 10)).now();
      s.onPhoneEvent(PhoneCallEvent.outgoing);
      s.onPhoneEvent(PhoneCallEvent.ringing);
      s.onCallNotification(title: 'Dave', text: 'Incoming call');
      expect(band.shown, ['Dave']);
      s.onPhoneEvent(PhoneCallEvent.answered);
      expect(band.clears, 1);
    });
  });

  test('phone event names round-trip from the platform channel', () {
    expect(PhoneCallEvent.parse('ringing'), PhoneCallEvent.ringing);
    expect(PhoneCallEvent.parse('answered'), PhoneCallEvent.answered);
    expect(PhoneCallEvent.parse('outgoing'), PhoneCallEvent.outgoing);
    expect(PhoneCallEvent.parse('ended'), PhoneCallEvent.ended);
    expect(PhoneCallEvent.parse('busy'), isNull);
  });

  test('extractNumber finds a dialable number and ignores short digit runs',
      () {
    expect(CallSession.extractNumber('+91 98765 43210'), '+919876543210');
    expect(CallSession.extractNumber('Alice (555) 123-4567'), '5551234567');
    expect(CallSession.extractNumber('Room 1234'), isNull);
    expect(CallSession.extractNumber('Alice'), isNull);
  });
}
