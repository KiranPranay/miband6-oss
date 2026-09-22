import 'package:flutter/services.dart';

import 'logger.dart';

/// Phone-side actions for the band's buttons, over the `band/call_control`
/// platform channel (`CallControlHost.kt`, registered on the process-lifetime
/// engine so it works with no activity alive).
///
/// Every call returns whether the action actually happened. Android telephony
/// APIs vary by version and OEM and several need runtime permissions, so the
/// caller — and, through it, the user — must never assume a press did
/// anything. See protocol-mb6.md §12.1.
class CallControl {
  CallControl(this._logger);

  static const MethodChannel _channel = MethodChannel('band/call_control');
  final BLELogger _logger;

  Future<bool> _call(String method, [Map<String, Object?>? args]) async {
    try {
      final r = await _channel.invokeMethod<bool>(method, args);
      _logger.i('CallControl.$method -> ${r == true}');
      return r == true;
    } on MissingPluginException {
      _logger.e('CallControl.$method: channel not registered');
      return false;
    } catch (e) {
      _logger.e('CallControl.$method failed: $e');
      return false;
    }
  }

  /// Declines a ringing call or hangs up an active one.
  Future<bool> endCall() => _call('endCall');

  /// Stops the ringer for the current call without declining it.
  Future<bool> silenceRinger() => _call('silenceRinger');

  /// Sends [text] to [number]. Needs SEND_SMS.
  Future<bool> sendSms(String number, String text) =>
      _call('sendSms', {'number': number, 'text': text});

  /// Find-my-phone: ring at full volume until [stopRinging].
  Future<bool> ringPhone() => _call('ringPhone');
  Future<bool> stopRinging() => _call('stopRinging');

  /// Which of the three runtime permissions are currently granted.
  Future<Map<String, bool>> permissions() async {
    try {
      final r = await _channel.invokeMethod<Map>('hasPermissions');
      return {
        for (final e in (r ?? const {}).entries)
          e.key.toString(): e.value == true,
      };
    } catch (_) {
      return const {};
    }
  }
}
