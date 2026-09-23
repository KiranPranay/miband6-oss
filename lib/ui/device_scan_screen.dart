import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/ble_manager.dart';

class DeviceScanScreen extends StatefulWidget {
  const DeviceScanScreen({super.key});

  @override
  State<DeviceScanScreen> createState() => _DeviceScanScreenState();
}

class _DeviceScanScreenState extends State<DeviceScanScreen> {
  final List<BluetoothDevice> _devices = [];
  bool _isScanning = false;

  /// Held so it can be cancelled. Each `_startScan` used to add another
  /// anonymous listener to the global `scanResults` stream and never remove it,
  /// so pressing Rescan N times left N listeners running — all still calling
  /// `setState` on this screen after it was popped, guarded only by `mounted`.
  StreamSubscription<List<ScanResult>>? _scanSub;

  @override
  void initState() {
    super.initState();
    _startScan();
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  Future<bool> _requestBlePermissions() async {
    if (await Permission.bluetoothScan.isDenied) {
      await Permission.bluetoothScan.request();
    }

    if (await Permission.bluetoothConnect.isDenied) {
      await Permission.bluetoothConnect.request();
    }

    if (await Permission.location.isDenied) {
      await Permission.location.request();
    }

    return await Permission.bluetoothScan.isGranted &&
        await Permission.bluetoothConnect.isGranted;
  }

  void _startScan() async {
    setState(() {
      _devices.clear();
      _isScanning = true;
    });

    bool hasPermissions = await _requestBlePermissions();
    if (!hasPermissions) {
      if (mounted) {
        setState(() => _isScanning = false);
      }
      return;
    }

    // We only filter for matching names generally, but just display all for safety
    FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));

    _scanSub?.cancel();
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      if (!mounted) return;
      for (ScanResult r in results) {
        if (!_devices.any((element) => element.remoteId == r.device.remoteId)) {
          if (r.device.platformName.isNotEmpty) {
            setState(() => _devices.add(r.device));
          }
        }
      }
    });

    await Future.delayed(const Duration(seconds: 10));
    if (mounted) {
      setState(() => _isScanning = false);
    }
  }

  void _connectToDevice(BluetoothDevice device) async {
    FlutterBluePlus.stopScan();
    // startSupervision (rather than a bare connect) records the user's intent
    // to stay connected, so the supervisor auto-reconnects after drops and the
    // band comes back on its own after an app restart or a reboot.
    await context.read<BLEManager>().startSupervision(target: device);
    if (!mounted) return;
    Navigator.pop(context); // Go back to Home
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan Devices'),
        actions: [
          if (_isScanning)
            const Padding(
              padding: EdgeInsets.only(right: 16.0),
              child: Center(
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                ),
              ),
            )
          else
            IconButton(icon: const Icon(Icons.refresh), onPressed: _startScan),
        ],
      ),
      body: ListView.builder(
        itemCount: _devices.length,
        itemBuilder: (context, index) {
          final device = _devices[index];
          return ListTile(
            title: Text(
              device.platformName.isEmpty
                  ? 'Unknown Device'
                  : device.platformName,
            ),
            subtitle: Text(device.remoteId.str),
            trailing: const Icon(Icons.arrow_forward_ios),
            onTap: () => _connectToDevice(device),
          );
        },
      ),
    );
  }
}
