import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'core/logger.dart';
import 'storage/secure_storage.dart';
import 'core/auth_manager.dart';
import 'core/ble_manager.dart';
import 'core/notification_relay.dart';

import 'ui/home_screen.dart';

/// Headless trigger for the hardware test session (see MainActivity.kt +
/// docs/reverse-engineering/capture-logs.md). Lets the adb loop start the test
/// with no manual taps via an intent extra.
const MethodChannel _hwTestChannel = MethodChannel('band/hwtest');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();

  final logger = BLELogger();
  final storage = StorageManager(logger);
  final bleManager = BLEManager(logger, storage);
  final notificationRelay = NotificationRelay(bleManager, logger);

  _wireHardwareTestTrigger(bleManager, logger);

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: logger),
        Provider.value(value: storage),
        ChangeNotifierProvider(create: (_) => AuthManager(logger, storage)),
        ChangeNotifierProvider.value(value: bleManager),
        ChangeNotifierProvider.value(value: notificationRelay),
      ],
      child: const MiBandApp(),
    ),
  );
}

void _wireHardwareTestTrigger(BLEManager ble, BLELogger logger) {
  // Hot trigger: app already running, intent arrives via onNewIntent.
  _hwTestChannel.setMethodCallHandler((call) async {
    if (call.method == 'runHardwareTest') {
      logger.i('MB6TEST: intent trigger received (hot) — will run after auth');
      await _runHwTestWhenAuthed(ble, logger);
    }
    return null;
  });
  // Cold start: ask native whether we were launched with --ez run_hwtest true.
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    try {
      final pending =
          await _hwTestChannel.invokeMethod<bool>('checkLaunchTrigger') ?? false;
      if (pending) {
        logger.i('MB6TEST: intent trigger received (cold launch) — '
            'will run after auth');
        await _runHwTestWhenAuthed(ble, logger);
      }
    } catch (e) {
      logger.d('MB6TEST: checkLaunchTrigger unavailable: $e');
    }
  });
}

/// Wait (up to 60 s) for the band to authenticate, then run the gated session.
/// Keeps Gate 1 pure (it only checks state); the waiting lives here in the glue.
Future<void> _runHwTestWhenAuthed(BLEManager ble, BLELogger logger) async {
  if (ble.isTestSessionRunning) {
    logger.i('MB6TEST: a session is already running — ignoring trigger');
    return;
  }
  for (var i = 0; i < 120; i++) {
    if (ble.authState == AuthState.authenticated) break;
    await Future.delayed(const Duration(milliseconds: 500));
  }
  if (ble.authState != AuthState.authenticated) {
    logger.e('MB6TEST: aborting trigger — band not authenticated after 60 s');
    return;
  }
  await ble.runHardwareTestSession();
}

class MiBandApp extends StatelessWidget {
  const MiBandApp({super.key});

  @override
  Widget build(BuildContext context) {
    return WithForegroundTask(
      child: MaterialApp(
        title: 'Mi Band',
        theme: ThemeData(
          brightness: Brightness.dark,
          primarySwatch: Colors.blue,
          useMaterial3: true,
        ),
        home: const _AppRoot(),
      ),
    );
  }
}

/// Triggers auto-connect once after the widget tree is ready.
class _AppRoot extends StatefulWidget {
  const _AppRoot();

  @override
  State<_AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<_AppRoot> {
  @override
  void initState() {
    super.initState();
    // Auto-connect to the last known device after the first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<BLEManager>().tryAutoConnect();
    });
  }

  @override
  Widget build(BuildContext context) => const HomeScreen();
}
