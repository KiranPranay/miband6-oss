import 'package:flutter_test/flutter_test.dart';
import 'package:band/core/device_events.dart';

/// Decoding of `fee0/0x0010` device events, protocol-mb6.md §12. Codes are
/// Gadgetbridge's `HuamiDeviceEvent` constants; offsets follow
/// `HuamiSupport.handleDeviceEvent`.
void main() {
  final t = DateTime(2026, 9, 23, 2, 15);

  test('every documented code decodes to its kind', () {
    const table = {
      0x01: BandEventKind.fellAsleep,
      0x02: BandEventKind.wokeUp,
      0x03: BandEventKind.stepsGoalReached,
      0x04: BandEventKind.buttonPressed,
      0x06: BandEventKind.startNonWear,
      0x07: BandEventKind.callReject,
      0x08: BandEventKind.findPhoneStart,
      0x09: BandEventKind.callIgnore,
      0x0a: BandEventKind.alarmToggled,
      0x0b: BandEventKind.buttonPressedLong,
      0x0e: BandEventKind.tick30Min,
      0x0f: BandEventKind.findPhoneStop,
      0x10: BandEventKind.silentMode,
      0x14: BandEventKind.workoutStarting,
      0x16: BandEventKind.mtuRequest,
      0x1a: BandEventKind.alarmChanged,
      0xfe: BandEventKind.musicControl,
    };
    table.forEach((code, kind) {
      expect(BandEvent.parse([code], at: t)!.kind, kind, reason: '0x${code.toRadixString(16)}');
    });
  });

  test('undefined codes are unknown, not misread', () {
    for (final c in [0x05, 0x0c, 0x0d, 0x11, 0x99]) {
      expect(BandEvent.parse([c], at: t)!.kind, BandEventKind.unknown);
    }
    expect(BandEvent.parse(const [], at: t), isNull);
  });

  test('silent mode carries its flag in value[1]', () {
    expect(BandEvent.parse([0x10, 0x01], at: t)!.silentModeOn, isTrue);
    expect(BandEvent.parse([0x10, 0x00], at: t)!.silentModeOn, isFalse);
  });

  test('MTU request is uint16 little-endian at value[1..2]', () {
    // 0x00F7 = 247, the usual negotiated MTU.
    expect(BandEvent.parse([0x16, 0xf7, 0x00], at: t)!.mtu, 247);
    expect(BandEvent.parse([0x16, 0x00, 0x01], at: t)!.mtu, 256);
  });

  test('music control sub-code is value[1]', () {
    expect(BandEvent.parse([0xfe, 0x03], at: t)!.musicAction, 3);
  });

  test('workout start carries GPS flag and type', () {
    final e = BandEvent.parse([0x14, 0x00, 0x01, 0x07], at: t)!;
    expect(e.workoutNeedsGps, isTrue);
    expect(e.workoutType, 7);
  });

  test('sleep and wear events are the persisted boundaries', () {
    expect(BandEvent.parse([0x01], at: t)!.isSleepBoundary, isTrue);
    expect(BandEvent.parse([0x02], at: t)!.isSleepBoundary, isTrue);
    expect(BandEvent.parse([0x06], at: t)!.isSleepBoundary, isTrue);
    expect(BandEvent.parse([0x07], at: t)!.isSleepBoundary, isFalse);
  });

  test('round-trips through JSON', () {
    final e = BandEvent.parse([0x02], at: t)!;
    final back = BandEvent.fromJson(e.toJson());
    expect(back.kind, BandEventKind.wokeUp);
    expect(back.at, t);
  });

  test('find-phone ack bytes match GB verbatim', () {
    expect(kFindPhoneAck, [0x06, 0x14, 0x00, 0x00]);
  });
}
