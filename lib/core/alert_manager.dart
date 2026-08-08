import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'huami_icon.dart';
import 'logger.dart';

/// Sends notifications (app / message / call alerts) to the Mi Band 6.
///
/// Wire format re-derived from Gadgetbridge for the **legacy** Huami path that
/// Mi Band 6 actually uses (`MiBand6Support → MiBand5Support → MiBand4Support →
/// MiBand3Support → AmazfitBipSupport → HuamiSupport`), cross-checked against
/// the decompiled Notify app. See `protocol-mb6.md` §8 and findings-17.
///
/// ## App notification — fee0 `0x0020`, "old chunked" framing, type 0
///
/// ```
/// [0xFA][0x00 0x00 0x00 0x00][0x01][iconId]
///   utf8(title)   0x00
///   utf8(body)    0x00
///   utf8(appName) 0x00
/// ```
///
/// Seven header bytes, then exactly three NUL-terminated UTF-8 fields. No
/// padding, no extra terminator. Text is capped at
/// `notificationMaxLength(230) - 7 = 223` bytes.
/// (`HuamiSupport.onNotification`.)
///
/// ## Incoming call — standard ANS `0x2A46`, unchunked
///
/// Mi Band 6 does **not** use `onSetCallStateNew` (that is wired only for
/// Bip3/BipS/GTS2/GTR2/ZeppE). It inherits `HuamiSupport.onSetCallState` →
/// `AmazfitBipTextNotificationStrategy.sendAlert`:
///
/// ```
/// [0x03][0x01] + utf8(caller)   → incoming call
/// [0x03][0x00]                  → dismiss
/// ```
///
/// ## What was wrong before (all five confirmed against GB + Notify)
///
/// 1. byte[6] carried `0xFA` instead of a real Huami icon id, and the `icon`
///    argument was silently discarded.
/// 2. The text fields were ordered `"" \0 body \0 title \0` — the app name was
///    never sent at all, and title/body were swapped.
/// 3. byte[5] was `0x00` where Gadgetbridge writes `0x01`.
/// 4. `stopCall()` sent a 10-byte frame on the wrong characteristic.
/// 5. Nothing was ever chunked: a single `[0x00, 0xC0, 0x00]` frame was used
///    unconditionally, which only works while the negotiated MTU stays above
///    the payload size. The MTU request is best-effort, so a long notification
///    on a 23-byte MTU link was simply truncated or rejected.
class AlertManager {
  AlertManager(this._logger);

  final BLELogger _logger;

  /// fee0 / `00000020-…` — the "old chunked" transport used for app alerts.
  BluetoothCharacteristic? _alertChar;

  /// Standard Alert Notification Service NEW_ALERT (`0x2A46`) — call alerts.
  BluetoothCharacteristic? _newAlertChar;

  /// Current negotiated ATT MTU; drives the chunk size.
  int _mtu = 23;

  void setCharacteristic(BluetoothCharacteristic? characteristic) {
    _alertChar = characteristic;
  }

  void setNewAlertCharacteristic(BluetoothCharacteristic? characteristic) {
    _newAlertChar = characteristic;
  }

  /// Record the negotiated MTU. Chunking is computed from this, so an
  /// unsuccessful `requestMtu` degrades to more, smaller frames rather than a
  /// silently truncated notification.
  void setMtu(int mtu) {
    _mtu = mtu.clamp(23, 517);
  }

  bool get isReady => _alertChar != null;

  /// `HuamiSupport.notificationMaxLength()` for the legacy path.
  static const int _maxCommandLength = 230;

  /// Bytes of header before the text fields.
  static const int _headerLength = 7;

  /// Budget for title + body + appName including their NUL terminators.
  static const int _maxTextBytes = _maxCommandLength - _headerLength; // 223

  int _notifId = 1;

  /// Send a generic app / message notification.
  ///
  /// [package] selects the band-side glyph via [HuamiIcon.forPackage]; pass an
  /// explicit [icon] to override. Returns the notification id (used for dedup
  /// bookkeeping by the relay).
  Future<int> sendAppNotification(
    String appName,
    String title,
    String message, {
    String? package,
    int? icon,
  }) async {
    final id = _notifId++ & 0xffffffff;
    final iconId = icon ?? HuamiIcon.forPackage(package);

    final command = buildAppNotification(
      appName: appName,
      title: title,
      body: message,
      iconId: iconId,
    );
    await _writeChunkedOld(command, 'app "$appName"');
    return id;
  }

  /// Builds the notification command bytes. Pure and separately unit-tested —
  /// this is the part that must match Gadgetbridge byte for byte.
  static Uint8List buildAppNotification({
    required String appName,
    required String title,
    required String body,
    required int iconId,
  }) {
    // Fall back so no field is empty: the band renders an empty title as a
    // blank row rather than collapsing it.
    final titleBytes = utf8.encode(title.isNotEmpty ? title : appName);
    final bodyBytes = utf8.encode(body.isNotEmpty ? body : title);
    final appBytes = utf8.encode(appName.isNotEmpty ? appName : 'Notification');

    // Trim to the device budget, keeping all three fields present. The body is
    // the elastic one — the title and app name identify the alert, so they are
    // preserved first.
    final fixed = titleBytes.length + appBytes.length + 3; // 3 NUL terminators
    final bodyBudget = (_maxTextBytes - fixed).clamp(0, _maxTextBytes);
    final trimmedBody = bodyBytes.length > bodyBudget
        ? _truncateUtf8(bodyBytes, bodyBudget)
        : bodyBytes;

    return Uint8List.fromList(<int>[
      0xFA, // CustomHuami notification command
      0x00, 0x00, 0x00, 0x00, // extra header (notificationHasExtraHeader)
      0x01, // constant, per HuamiSupport.onNotification
      iconId & 0xFF,
      ...titleBytes, 0x00,
      ...trimmedBody, 0x00,
      ...appBytes, 0x00,
    ]);
  }

  /// Truncates a UTF-8 byte list to at most [max] bytes without splitting a
  /// multi-byte sequence (which would render as a replacement glyph).
  static List<int> _truncateUtf8(List<int> bytes, int max) {
    if (bytes.length <= max) return bytes;
    var end = max;
    // Walk back off any continuation byte (0b10xxxxxx).
    while (end > 0 && (bytes[end] & 0xC0) == 0x80) {
      end--;
    }
    return bytes.sublist(0, end);
  }

  /// Send a message/SMS alert (sender + text).
  Future<void> sendSms(String sender, String message) => sendAppNotification(
        'Messages',
        sender,
        message,
        icon: HuamiIcon.message,
      );

  /// Send an incoming-call alert. Call [stopCall] when it ends.
  ///
  /// Uses the standard ANS characteristic, which is what Gadgetbridge does for
  /// Mi Band 6 — the chunked `onSetCallStateNew` form belongs to other models.
  Future<void> sendIncomingCall(String caller) async {
    final name = caller.isEmpty ? 'Call' : caller;
    final cmd = Uint8List.fromList([0x03, 0x01, ...utf8.encode(name)]);
    await _writeNewAlert(cmd, 'call "$name"');
  }

  /// Dismiss an active incoming-call alert (answered / ended).
  Future<void> stopCall() =>
      _writeNewAlert(Uint8List.fromList([0x03, 0x00]), 'call-end');

  /// Developer self-test.
  Future<void> sendTest() => sendAppNotification(
        'Mi Band',
        'Test',
        'If you can read this, notifications work.',
        icon: HuamiIcon.chatBlue,
      );

  // ── Transport ─────────────────────────────────────────────────────────────

  /// Maximum payload bytes per chunk.
  ///
  /// `calcMaxWriteChunk(mtu) - 3`, where
  /// `calcMaxWriteChunk = min(512, max(23, mtu) - 3)`
  /// (`AbstractBTLEDeviceSupport.calcMaxWriteChunk`). 17 bytes at MTU 23,
  /// 241 at MTU 247.
  int get maxChunkLength => chunkLengthForMtu(_mtu);

  static int chunkLengthForMtu(int mtu) {
    final maxWrite = (mtu < 23 ? 23 : mtu) - 3;
    return (maxWrite > 512 ? 512 : maxWrite) - 3;
  }

  /// Splits [command] into `writeToChunkedOld` frames.
  ///
  /// Frame layout: `[0x00][flags | type][count][payload…]` with type 0 for
  /// notifications. Flags: `0x80` last chunk, `0x40` additionally on a
  /// single-chunk message (giving `0xC0`) or alone on a consecutive middle
  /// chunk, `0x00` on the first of several. (`HuamiSupport.writeToChunkedOld`.)
  static List<Uint8List> buildChunks(
    List<int> command, {
    required int maxChunkLength,
    int type = 0,
  }) {
    final frames = <Uint8List>[];
    var offset = 0;
    var count = 0;
    var remaining = command.length;

    // A zero-length command still needs one frame so the band sees the type.
    if (remaining == 0) {
      return [
        Uint8List.fromList([0x00, 0xC0 | type, 0x00])
      ];
    }

    while (remaining > 0) {
      final copy = remaining < maxChunkLength ? remaining : maxChunkLength;
      var flags = 0;
      if (remaining <= maxChunkLength) {
        flags |= 0x80; // last chunk
        if (count == 0) flags |= 0x40; // …and the only one
      } else if (count > 0) {
        flags |= 0x40; // consecutive middle chunk
      }
      frames.add(Uint8List.fromList([
        0x00,
        (flags | type) & 0xFF,
        count & 0xFF,
        ...command.sublist(offset, offset + copy),
      ]));
      offset += copy;
      remaining -= copy;
      count++;
    }
    return frames;
  }

  Future<void> _writeChunkedOld(List<int> command, String label) async {
    final ch = _alertChar;
    if (ch == null) {
      _logger.e('Notif: 0x0020 characteristic not available — cannot send $label');
      return;
    }
    final frames = buildChunks(command, maxChunkLength: maxChunkLength);
    final noResp = !ch.properties.write && ch.properties.writeWithoutResponse;
    try {
      for (final frame in frames) {
        await ch.write(frame, withoutResponse: noResp);
      }
      _logger.i('Notif: sent $label — ${command.length} B in '
          '${frames.length} chunk(s) of ≤$maxChunkLength B '
          '(mtu=$_mtu, withoutResponse=$noResp)');
    } catch (e) {
      _logger.e('Notif: failed to send $label: $e');
    }
  }

  Future<void> _writeNewAlert(List<int> command, String label) async {
    final ch = _newAlertChar;
    if (ch == null) {
      _logger.e('Notif: 0x2A46 (NEW_ALERT) not available — cannot send $label');
      return;
    }
    final noResp = !ch.properties.write && ch.properties.writeWithoutResponse;
    try {
      await ch.write(command, withoutResponse: noResp);
      _logger.i('Notif: sent $label (${command.length} B) to 0x2A46');
    } catch (e) {
      _logger.e('Notif: failed to send $label: $e');
    }
  }
}
