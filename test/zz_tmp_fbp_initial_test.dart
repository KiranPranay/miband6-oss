import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

final class _FakePlatform extends FlutterBluePlusPlatform {
  final _conn = StreamController<BmConnectionStateResponse>.broadcast();
  @override
  Stream<BmConnectionStateResponse> get onConnectionStateChanged => _conn.stream;
}

void main() {
  test('connectionState replays disconnected before an awaited connect', () async {
    FlutterBluePlusPlatform.instance = _FakePlatform();
    final d = BluetoothDevice.fromId('AA:BB:CC:DD:EE:FF');

    final events = <BluetoothConnectionState>[];
    final order = <String>[];

    final sub = d.connectionState.listen((s) {
      events.add(s);
      order.add('event:$s');
    });

    // Simulate `await target.connect(...)` — a single async gap.
    order.add('before-await');
    await Future<void>.delayed(Duration.zero);
    order.add('after-await');

    // ignore: avoid_print
    print('EVENTS: $events');
    // ignore: avoid_print
    print('ORDER: $order');

    await sub.cancel();
  });
}
