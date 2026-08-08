import 'dart:convert';

import 'package:band/core/alert_manager.dart';
import 'package:band/core/huami_icon.dart';
import 'package:flutter_test/flutter_test.dart';

/// Byte-level tests for the Mi Band 6 notification wire format.
///
/// The payload is re-derived from Gadgetbridge's legacy Huami path
/// (`HuamiSupport.onNotification` / `writeToChunkedOld`) and cross-checked
/// against the decompiled Notify app — see `protocol-mb6.md` §8 and
/// findings-17. These tests pin the exact bytes so a refactor cannot silently
/// reintroduce any of the five defects the old implementation had.

/// Splits a command on NUL into its text fields (after the 7-byte header).
List<String> _textFields(List<int> cmd) {
  final body = cmd.sublist(7);
  final fields = <String>[];
  var start = 0;
  for (var i = 0; i < body.length; i++) {
    if (body[i] == 0x00) {
      fields.add(utf8.decode(body.sublist(start, i)));
      start = i + 1;
    }
  }
  return fields;
}

void main() {
  group('app notification payload', () {
    test('header is FA 00 00 00 00 01 <icon>', () {
      final cmd = AlertManager.buildAppNotification(
        appName: 'WhatsApp',
        title: 'Alice',
        body: 'Hi',
        iconId: HuamiIcon.whatsapp,
      );

      expect(cmd[0], 0xFA, reason: 'CustomHuami notification command');
      expect(cmd.sublist(1, 5), [0x00, 0x00, 0x00, 0x00],
          reason: 'notificationHasExtraHeader block');
      expect(cmd[5], 0x01,
          reason: 'constant 0x01 — the old code wrongly sent 0x00 here');
      expect(cmd[6], HuamiIcon.whatsapp,
          reason: 'real icon id — the old code hard-coded 0xFA here');
    });

    test('carries exactly three NUL-terminated fields: title, body, app', () {
      final cmd = AlertManager.buildAppNotification(
        appName: 'WhatsApp',
        title: 'Alice',
        body: 'Hi there',
        iconId: HuamiIcon.whatsapp,
      );

      // The old order was ["", body, title] with the app name never sent.
      expect(_textFields(cmd), ['Alice', 'Hi there', 'WhatsApp']);
      expect(cmd.last, 0x00, reason: 'trailing NUL terminates the app name');
    });

    test('matches the byte-for-byte Gadgetbridge example', () {
      final cmd = AlertManager.buildAppNotification(
        appName: 'WhatsApp',
        title: 'Alice',
        body: 'Hi',
        iconId: HuamiIcon.whatsapp,
      );
      expect(cmd, [
        0xFA, 0x00, 0x00, 0x00, 0x00, 0x01, 0x07, // header, icon 7 = WhatsApp
        0x41, 0x6C, 0x69, 0x63, 0x65, 0x00, //       "Alice\0"
        0x48, 0x69, 0x00, //                         "Hi\0"
        0x57, 0x68, 0x61, 0x74, 0x73, 0x41, 0x70, 0x70, 0x00, // "WhatsApp\0"
      ]);
    });

    test('never exceeds the 230-byte command budget', () {
      final cmd = AlertManager.buildAppNotification(
        appName: 'App',
        title: 'T',
        body: 'x' * 5000,
        iconId: HuamiIcon.genericApp,
      );
      expect(cmd.length, lessThanOrEqualTo(230));
      // All three fields survive truncation — the body is the elastic one.
      expect(_textFields(cmd).length, 3);
      expect(_textFields(cmd)[0], 'T');
      expect(_textFields(cmd)[2], 'App');
    });

    test('truncation never splits a multi-byte UTF-8 character', () {
      final cmd = AlertManager.buildAppNotification(
        appName: 'App',
        title: 'T',
        // 4-byte emoji repeated: a naive byte cut would leave a partial glyph.
        body: '😀' * 200,
        iconId: HuamiIcon.genericApp,
      );
      final fields = _textFields(cmd);
      expect(fields.length, 3);
      // Decoding already succeeded inside _textFields; assert no replacement
      // character was produced.
      expect(fields[1].contains('�'), isFalse);
    });

    test('empty fields fall back rather than sending a blank row', () {
      final cmd = AlertManager.buildAppNotification(
        appName: 'Gmail',
        title: '',
        body: '',
        iconId: HuamiIcon.email,
      );
      final fields = _textFields(cmd);
      expect(fields[0], 'Gmail', reason: 'title falls back to the app name');
      expect(fields[2], 'Gmail');
    });
  });

  group('old-chunked framing', () {
    test('chunk length follows calcMaxWriteChunk(mtu) - 3', () {
      // min(512, max(23, mtu) - 3) - 3
      expect(AlertManager.chunkLengthForMtu(23), 17);
      expect(AlertManager.chunkLengthForMtu(247), 241);
      expect(AlertManager.chunkLengthForMtu(20), 17, reason: 'clamped up to 23');
    });

    test('a short command is one frame flagged 0xC0', () {
      final frames = AlertManager.buildChunks(
        List<int>.filled(10, 0xAA),
        maxChunkLength: 241,
      );
      expect(frames.length, 1);
      expect(frames.single[0], 0x00);
      expect(frames.single[1], 0xC0, reason: 'last | first == single chunk');
      expect(frames.single[2], 0x00, reason: 'count');
      expect(frames.single.length, 13);
    });

    test('a long command splits with correct flags and counts', () {
      // 27 bytes at MTU 23 (17-byte chunks) → 17 + 10.
      final cmd = List<int>.generate(27, (i) => i);
      final frames = AlertManager.buildChunks(cmd, maxChunkLength: 17);

      expect(frames.length, 2);
      // First of several: flags 0x00.
      expect(frames[0][1], 0x00);
      expect(frames[0][2], 0x00);
      expect(frames[0].sublist(3), cmd.sublist(0, 17));
      // Last chunk, count > 0: flags 0x80 (not 0xC0).
      expect(frames[1][1], 0x80);
      expect(frames[1][2], 0x01);
      expect(frames[1].sublist(3), cmd.sublist(17));
    });

    test('a middle chunk of a three-part message is flagged 0x40', () {
      final cmd = List<int>.filled(40, 0x5A);
      final frames = AlertManager.buildChunks(cmd, maxChunkLength: 17);

      expect(frames.length, 3);
      expect(frames[0][1], 0x00, reason: 'first of several');
      expect(frames[1][1], 0x40, reason: 'consecutive middle chunk');
      expect(frames[2][1], 0x80, reason: 'last');
      expect(frames.map((f) => f[2]).toList(), [0, 1, 2]);
    });

    test('reassembling the frames reproduces the command exactly', () {
      final cmd = List<int>.generate(500, (i) => i % 256);
      for (final chunkLen in [17, 60, 241]) {
        final frames =
            AlertManager.buildChunks(cmd, maxChunkLength: chunkLen);
        final rebuilt = <int>[];
        for (final f in frames) {
          rebuilt.addAll(f.sublist(3));
        }
        expect(rebuilt, cmd, reason: 'chunk length $chunkLen');
      }
    });

    test('a real notification at MTU 23 spans several frames', () {
      final cmd = AlertManager.buildAppNotification(
        appName: 'WhatsApp',
        title: 'Alice',
        body: 'A message long enough to need more than one BLE write.',
        iconId: HuamiIcon.whatsapp,
      );
      final frames = AlertManager.buildChunks(cmd, maxChunkLength: 17);
      expect(frames.length, greaterThan(1),
          reason: 'the old code sent one frame unconditionally and truncated');
      expect(frames.last[1] & 0x80, 0x80, reason: 'final frame marked last');
    });
  });

  group('icon mapping', () {
    test('known packages map to Gadgetbridge ids', () {
      expect(HuamiIcon.forPackage('com.whatsapp'), 7);
      expect(HuamiIcon.forPackage('org.telegram.messenger'), 25);
      expect(HuamiIcon.forPackage('com.google.android.gm'), 34);
      expect(HuamiIcon.forPackage('com.facebook.katana'), 3);
    });

    test('unknown or missing packages use the generic app icon', () {
      expect(HuamiIcon.forPackage('com.example.unheard'), HuamiIcon.genericApp);
      expect(HuamiIcon.forPackage(''), HuamiIcon.genericApp);
      expect(HuamiIcon.forPackage(null), HuamiIcon.genericApp);
    });
  });
}
