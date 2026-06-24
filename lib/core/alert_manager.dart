import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'logger.dart';

/// Sends notifications (app / message / call alerts) to the Mi Band 6 using the
/// Huami notification format over the "old chunked" characteristic fee0/0x0020.
///
/// Command (Gadgetbridge `HuamiSupport.onNotification`, CustomHuami category):
///   `[0xFA, 0x01, iconId] + utf8(body) + 0x00 + utf8(appName) + 0x00`
/// Incoming call (`onSetCallStateNew`):
///   `[0x03, 0,0,0,0,0] + utf8(caller) + [0,0,0,2]`
/// Each command is wrapped in one old-chunked frame: `[0x00, 0xC0, 0x00] + cmd`
/// (0xC0 = first|last chunk, count 0).
class AlertManager {
  final BLELogger _logger;
  BluetoothCharacteristic? _alertChar;

  AlertManager(this._logger);

  void setCharacteristic(BluetoothCharacteristic? characteristic) {
    _alertChar = characteristic;
  }

  bool get isReady => _alertChar != null;

  static const int _maxLen = 230;

  // HuamiIcon ids.
  static const int iconApp = 11; // APP_11 (generic)
  static const int iconMessage = 0; // WECHAT (chat bubble)
  static const int iconChat = 13; // CHAT_BLUE_13
  static const int iconEmail = 34; // EMAIL

  int _notifId = 1;

  /// Send a generic app / message notification.
  ///
  /// Exact MILI_PANGU (Mi Band 6) format from the Notify app's own builder
  /// (decompiled y5/q.java::o, default path), sent PLAINTEXT to fee0/0x0020 in a
  /// single old-chunked frame — the same channel as the working incoming call:
  ///   [0xFA, 0x00, id(4 LE), CAT=0xFA, 0x00, body\0, title\0, pad→≥18]
  /// (Missing the 4-byte id header / 18-byte padding is why earlier attempts
  /// showed the empty "No notifications" screen.) Returns the notification id.
  Future<int> sendAppNotification(String appName, String title, String message,
      {int icon = iconApp}) async {
    final id = _notifId++ & 0xffffffff;
    final titleBytes = utf8.encode(title.isEmpty ? appName : title);
    final bodyBytes = utf8.encode(message.isEmpty ? appName : message);

    final inner = <int>[
      0xFA, // category byte (CustomHuami -6)
      0x00, // subtype flag (full notification)
      id & 0xff, (id >> 8) & 0xff, (id >> 16) & 0xff, (id >> 24) & 0xff,
      0xFA, // CAT (generic)
      0x00, // empty title slot (leading null)
      ...bodyBytes, 0x00,
      ...titleBytes, 0x00,
    ];
    while (inner.length < 18) {
      inner.add(0x00); // zero-pad to the minimum length the band expects
    }
    await _writeFramed(inner, 'app "$appName"');
    return id;
  }

  /// Send a message/SMS alert (sender + text).
  Future<void> sendSms(String sender, String message) =>
      sendAppNotification('Messages', sender, message, icon: iconMessage);

  /// Send an incoming-call alert (caller name). Call [stopCall] when it ends.
  Future<void> sendIncomingCall(String caller) async {
    final cmd = <int>[
      0x03, 0, 0, 0, 0, 0, //
      ...utf8.encode(caller.isEmpty ? 'Call' : caller),
      0, 0, 0, 2,
    ];
    await _writeFramed(cmd, 'call "$caller"');
  }

  /// Dismiss an active incoming-call alert (call answered / ended).
  Future<void> stopCall() async {
    // Category 3 with the "end" trailer (…,0,0,0,3) dismisses the call screen.
    final cmd = <int>[0x03, 0, 0, 0, 0, 0, 0, 0, 0, 3];
    await _writeFramed(cmd, 'call-end');
  }

  /// Developer self-test.
  Future<void> sendTest() =>
      sendAppNotification('Mi Band', 'Test', 'Test notification', icon: iconChat);

  Future<void> _writeFramed(List<int> command, String label) async {
    final ch = _alertChar;
    if (ch == null) {
      _logger.e('Notif: 0x0020 characteristic not available');
      return;
    }
    // Truncate to the device max, then wrap in a single old-chunked frame.
    final cmd =
        command.length > _maxLen ? command.sublist(0, _maxLen) : command;
    final frame = Uint8List.fromList([0x00, 0xC0, 0x00, ...cmd]);
    try {
      final noResp = !ch.properties.write && ch.properties.writeWithoutResponse;
      await ch.write(frame, withoutResponse: noResp);
      _logger.i('Notif: sent $label (${frame.length} B) to 0x0020 '
          '(withoutResponse=$noResp)');
    } catch (e) {
      _logger.e('Notif: failed to send $label: $e');
    }
  }
}
