import 'package:band/core/band_config.dart';
import 'package:flutter_test/flutter_test.dart';

/// Byte-level tests for the Mi Band 6 configuration commands.
///
/// These matter more than usual: the band **accepts and silently ignores** a
/// command it does not understand, so a wrong byte or a wrong target
/// characteristic produces a setting that appears to work in the UI and does
/// nothing on the wrist. Every expectation below is pinned to the Gadgetbridge
/// source cited in `protocol-mb6.md` §9.

void main() {
  group('heart rate', () {
    test('interval is written in MINUTES to the HR control point', () {
      final c = BandCommands.hrInterval(HrInterval.fiveMinutes);
      expect(c.target, ConfigTarget.heartRateControl,
          reason: '0x2A39, not the config characteristic');
      expect(c.bytes, [0x14, 5], reason: 'minutes, not seconds');
    });

    test('off disables periodic measurement with interval 0', () {
      expect(BandCommands.hrInterval(HrInterval.off).bytes, [0x14, 0]);
    });

    test('only the intervals Mi Band 6 supports are offered', () {
      expect(HrInterval.values.map((e) => e.minutes).toList(),
          [0, 1, 5, 10, 30]);
    });

    test('sleep-assisted uses the shared 0x15 mode setter', () {
      expect(BandCommands.hrSleepAssisted(true).bytes, [0x15, 0x00, 0x01]);
      expect(BandCommands.hrSleepAssisted(false).bytes, [0x15, 0x00, 0x00]);
      expect(BandCommands.hrSleepAssisted(true).target,
          ConfigTarget.heartRateControl);
    });

    test('all-day monitoring goes to the config characteristic', () {
      final c = BandCommands.hrAllDayMonitoring(true);
      expect(c.bytes, [0x06, 0x22, 0x00, 0x01]);
      expect(c.target, ConfigTarget.configuration);
    });

    test('high alert carries the threshold as raw bpm', () {
      expect(BandCommands.hrHighAlert(true, 150).bytes,
          [0x06, 0x1A, 0x00, 0x01, 150]);
      expect(BandCommands.hrHighAlert(false, 150).bytes,
          [0x06, 0x1A, 0x00, 0x00, 150]);
    });
  });

  group('stress', () {
    test('monitoring toggle uses opcode 0xFE', () {
      expect(BandCommands.stressMonitoring(true).bytes,
          [0xFE, 0x06, 0x00, 0x01]);
      expect(BandCommands.stressMonitoring(false).bytes,
          [0xFE, 0x06, 0x00, 0x00]);
    });
  });

  group('lift wrist', () {
    test('off is the 4-byte form', () {
      expect(BandCommands.liftWrist(LiftWristMode.off).bytes,
          [0x06, 0x05, 0x00, 0x00]);
    });

    test('always is the 8-byte form with a zeroed schedule', () {
      // Distinct from OFF — a zeroed schedule means "all day", not "disabled".
      expect(BandCommands.liftWrist(LiftWristMode.always).bytes,
          [0x06, 0x05, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]);
    });

    test('scheduled encodes start/end as plain 24h binary', () {
      final c = BandCommands.liftWrist(
        LiftWristMode.scheduled,
        start: const BandTime(8, 30),
        end: const BandTime(22, 15),
      );
      expect(c.bytes, [0x06, 0x05, 0x00, 0x01, 8, 30, 22, 15]);
    });

    test('sensitivity', () {
      expect(BandCommands.liftWristSensitivity(LiftWristSensitivity.normal).bytes,
          [0x06, 0x23, 0x00, 0x00]);
      expect(
          BandCommands.liftWristSensitivity(LiftWristSensitivity.sensitive)
              .bytes,
          [0x06, 0x23, 0x00, 0x01]);
    });
  });

  group('do not disturb', () {
    test('off / automatic / scheduled', () {
      expect(BandCommands.doNotDisturb(DndMode.off).bytes, [0x09, 0x82]);
      expect(BandCommands.doNotDisturb(DndMode.automatic).bytes, [0x09, 0x83]);
      expect(
        BandCommands.doNotDisturb(
          DndMode.scheduled,
          start: const BandTime(23, 0),
          end: const BandTime(7, 30),
        ).bytes,
        [0x09, 0x81, 23, 0, 7, 30],
      );
    });

    test('allowing lift-wrist during DND clears bit 0x80', () {
      expect(
        BandCommands.doNotDisturb(DndMode.automatic, allowLiftWrist: true).bytes,
        [0x09, 0x03],
        reason: '0x83 -> 0x03',
      );
      expect(
        BandCommands.doNotDisturb(
          DndMode.scheduled,
          start: const BandTime(1, 0),
          end: const BandTime(6, 0),
          allowLiftWrist: true,
        ).bytes,
        [0x09, 0x01, 1, 0, 6, 0],
        reason: '0x81 -> 0x01',
      );
    });
  });

  group('night mode', () {
    test('uses its own opcode 0x1A, separate from DND', () {
      expect(BandCommands.nightMode(NightMode.off).bytes, [0x1A, 0x00]);
      expect(BandCommands.nightMode(NightMode.sunset).bytes, [0x1A, 0x02]);
      expect(
        BandCommands.nightMode(
          NightMode.scheduled,
          start: const BandTime(22, 0),
          end: const BandTime(7, 0),
        ).bytes,
        [0x1A, 0x01, 22, 0, 7, 0],
      );
    });
  });

  group('display + units', () {
    test('time format', () {
      expect(BandCommands.timeFormat(TimeFormat.twentyFourHour).bytes,
          [0x06, 0x02, 0x00, 0x01]);
      expect(BandCommands.timeFormat(TimeFormat.twelveHour).bytes,
          [0x06, 0x02, 0x00, 0x00]);
    });

    test('date display uses 0x03 for date+time', () {
      expect(BandCommands.showDate(true).bytes, [0x06, 0x0A, 0x00, 0x03]);
      expect(BandCommands.showDate(false).bytes, [0x06, 0x0A, 0x00, 0x00]);
    });

    test('date format is always 13 bytes with a 10-byte ASCII pattern', () {
      final c = BandCommands.dateFormat('dd/MM/yyyy');
      expect(c.bytes.length, 13);
      expect(c.bytes.sublist(0, 3), [0x06, 0x1E, 0x00]);
      expect(String.fromCharCodes(c.bytes.sublist(3)), 'dd/MM/yyyy');
    });

    test('a short date pattern is zero-padded, a long one truncated', () {
      expect(BandCommands.dateFormat('dd/MM').bytes.length, 13);
      expect(BandCommands.dateFormat('dd/MM/yyyy/extra').bytes.length, 13);
    });

    test('distance unit', () {
      expect(BandCommands.distanceUnit(DistanceUnit.metric).bytes,
          [0x06, 0x03, 0x00, 0x00]);
      expect(BandCommands.distanceUnit(DistanceUnit.imperial).bytes,
          [0x06, 0x03, 0x00, 0x01]);
    });
  });

  group('user settings characteristic', () {
    test('wear wrist goes to 0x0008, NOT the config characteristic', () {
      final left = BandCommands.wearWrist(WearWrist.left);
      final right = BandCommands.wearWrist(WearWrist.right);
      expect(left.target, ConfigTarget.userSettings);
      expect(left.bytes, [0x20, 0x00, 0x00, 0x02]);
      expect(right.bytes, [0x20, 0x00, 0x00, 0x82]);
    });

    test('step goal is uint16 little-endian', () {
      final c = BandCommands.stepGoal(10000); // 0x2710
      expect(c.target, ConfigTarget.userSettings);
      expect(c.bytes, [0x10, 0x00, 0x00, 0x10, 0x27, 0x00, 0x00]);
    });

    test('step goal is clamped to the 16-bit field', () {
      expect(BandCommands.stepGoal(999999).bytes.sublist(3, 5), [0xFF, 0xFF]);
    });

    test('goal notification', () {
      expect(BandCommands.goalNotification(true).bytes,
          [0x06, 0x06, 0x00, 0x01]);
    });
  });

  group('inactivity warnings', () {
    test('enabled form is 12 bytes with threshold at index 2', () {
      final c = BandCommands.inactivityWarnings(
        enabled: true,
        thresholdMinutes: 60,
        start: const BandTime(9, 0),
        end: const BandTime(21, 30),
      );
      expect(c.bytes.length, 12);
      expect(c.bytes[0], 0x08);
      expect(c.bytes[1], 0x01);
      expect(c.bytes[2], 60, reason: 'threshold in minutes');
      expect(c.bytes.sublist(4, 8), [9, 0, 21, 30], reason: 'window 1');
      expect(c.bytes.sublist(8, 12), [0, 0, 0, 0],
          reason: 'window 2 unused when there is no quiet period');
    });

    test('a quiet period splits the day into two windows', () {
      final c = BandCommands.inactivityWarnings(
        enabled: true,
        thresholdMinutes: 30,
        start: const BandTime(8, 0),
        end: const BandTime(22, 0),
        dndStart: const BandTime(12, 0),
        dndEnd: const BandTime(13, 0),
      );
      expect(c.bytes.sublist(4, 8), [8, 0, 12, 0]);
      expect(c.bytes.sublist(8, 12), [13, 0, 22, 0]);
    });

    test('disabled form keeps the 12-byte shape', () {
      final c = BandCommands.inactivityWarnings(enabled: false);
      expect(c.bytes.length, 12);
      expect(c.bytes[1], 0x00);
    });
  });

  group('vibration', () {
    test('vibrate targets the Immediate Alert level characteristic', () {
      expect(BandCommands.vibrate.target, ConfigTarget.alertLevel);
      expect(BandCommands.vibrate.bytes, [0x03]);
      expect(BandCommands.stopVibrate.bytes, [0x00]);
    });
  });

  group('display items', () {
    test('four bytes per entry, sent over the chunked characteristic', () {
      final c = BandCommands.displayItems([
        BandCommands.menuItems['status']!,
        BandCommands.menuItems['heartRate']!,
      ]);
      expect(c.target, ConfigTarget.chunked);
      expect(c.bytes, [0x1E, 0, 0x00, 0xFF, 0x01, 1, 0x00, 0xFF, 0x02]);
    });
  });

  group('BandSettings', () {
    test('produces one command per setting, ending with the HR interval', () {
      final commands = const BandSettings().toCommands();
      expect(commands.length, greaterThan(10));
      expect(commands.last.bytes.first, 0x14,
          reason: 'HR interval last — it is the externally observable one');
    });

    test('round-trips through JSON', () {
      const s = BandSettings(
        hrInterval: HrInterval.tenMinutes,
        stressMonitoring: true,
        wearWrist: WearWrist.right,
        distanceUnit: DistanceUnit.imperial,
        timeFormat: TimeFormat.twelveHour,
        stepGoal: 8000,
        dnd: DndMode.scheduled,
        dndStart: BandTime(23, 15),
        liftWrist: LiftWristMode.scheduled,
        inactivityEnabled: true,
        inactivityThresholdMinutes: 45,
      );
      final back = BandSettings.fromJson(s.toJson());

      expect(back.hrInterval, HrInterval.tenMinutes);
      expect(back.stressMonitoring, isTrue);
      expect(back.wearWrist, WearWrist.right);
      expect(back.distanceUnit, DistanceUnit.imperial);
      expect(back.timeFormat, TimeFormat.twelveHour);
      expect(back.stepGoal, 8000);
      expect(back.dnd, DndMode.scheduled);
      expect(back.dndStart.h, 23);
      expect(back.dndStart.m, 15);
      expect(back.liftWrist, LiftWristMode.scheduled);
      expect(back.inactivityEnabled, isTrue);
      expect(back.inactivityThresholdMinutes, 45);
    });

    test('unknown or corrupt JSON falls back to defaults, never throws', () {
      final back = BandSettings.fromJson({
        'hrInterval': 'nonsense',
        'wearWrist': 42,
        'dndStart': 'not-a-time',
      });
      expect(back.hrInterval, HrInterval.off);
      expect(back.wearWrist, WearWrist.left);
      expect(back.dndStart.h, 1);
    });

    test('copyWith changes only the named field', () {
      const s = BandSettings(stepGoal: 5000);
      final t = s.copyWith(hrInterval: HrInterval.oneMinute);
      expect(t.stepGoal, 5000);
      expect(t.hrInterval, HrInterval.oneMinute);
      expect(s.hrInterval, HrInterval.off, reason: 'original is untouched');
    });
  });
}
