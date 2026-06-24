import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/auth_manager.dart';
import '../core/ble_manager.dart';
import 'device_scan_screen.dart';
import 'auth_key_screen.dart';
import 'debug_console.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final authManager = context.watch<AuthManager>();
    final bleManager = context.watch<BLEManager>();

    return Scaffold(
      backgroundColor: const Color(0xFF0F0F1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F0F1A),
        elevation: 0,
        title: const Text(
          'Settings',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        iconTheme: const IconThemeData(color: Colors.white70),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          // ── Band Status Card ─────────────────────────────────────────
          _BandStatusCard(bleManager: bleManager),

          const SizedBox(height: 20),

          // ── Device ───────────────────────────────────────────────────
          _SectionHeader(title: 'Device'),
          _SettingsTile(
            icon: Icons.bluetooth_searching,
            title: 'Scan & Connect',
            subtitle: bleManager.device != null
                ? bleManager.device!.remoteId.str
                : 'No device paired',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const DeviceScanScreen()),
            ),
          ),
          if (bleManager.isConnected)
            _SettingsTile(
              icon: Icons.cancel,
              iconColor: Colors.redAccent,
              title: 'Disconnect',
              titleColor: Colors.redAccent,
              subtitle: 'Stops auto-reconnect',
              onTap: () => bleManager.disconnect(),
            ),

          const SizedBox(height: 8),

          // ── Auth ──────────────────────────────────────────────────────
          _SectionHeader(title: 'Authentication'),
          _SettingsTile(
            icon: Icons.key_rounded,
            title: 'Auth Key',
            subtitle: authManager.hasKey ? 'Key is set ✓' : 'No key set',
            subtitleColor: authManager.hasKey ? Colors.green : Colors.orange,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AuthKeyScreen()),
            ),
          ),

          const SizedBox(height: 8),

          // ── Developer ────────────────────────────────────────────────
          _SectionHeader(title: 'Developer'),
          _SettingsTile(
            icon: Icons.bug_report_outlined,
            title: 'Debug Log',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const DebugConsole()),
            ),
          ),
          _SettingsTile(
            icon: bleManager.isTestSessionRunning
                ? Icons.hourglass_top
                : Icons.science_outlined,
            title: 'Run Hardware Test',
            subtitle: bleManager.isTestSessionRunning
                ? 'Running gates 0→6 — watch the Debug Log…'
                : 'Verify HR / battery / fetch on the band (wear it first)',
            iconColor: bleManager.isTestSessionRunning
                ? Colors.amberAccent
                : Colors.lightGreenAccent,
            onTap: () => _onRunHardwareTest(context, bleManager),
          ),
          _SettingsTile(
            icon: Icons.notifications_active_outlined,
            title: 'Send Test Notification',
            subtitle: 'Push a test alert to the band',
            iconColor: Colors.tealAccent,
            onTap: () => _onSendTestNotification(context, bleManager),
          ),
        ],
      ),
    );
  }

  void _onSendTestNotification(BuildContext context, BLEManager bleManager) {
    final messenger = ScaffoldMessenger.of(context);
    if (!bleManager.isConnected ||
        bleManager.authState != AuthState.authenticated) {
      messenger.showSnackBar(const SnackBar(
        content: Text('Connect & authenticate the band first'),
      ));
      return;
    }
    bleManager.alertManager.sendTest();
    messenger.showSnackBar(const SnackBar(
      content: Text('Test notification sent — check your band'),
    ));
  }

  void _onRunHardwareTest(BuildContext context, BLEManager bleManager) {
    final messenger = ScaffoldMessenger.of(context);
    if (bleManager.isTestSessionRunning) {
      messenger.showSnackBar(const SnackBar(
        content: Text('Hardware test already running — see Debug Log'),
      ));
      return;
    }
    if (!bleManager.isConnected ||
        bleManager.authState != AuthState.authenticated) {
      messenger.showSnackBar(const SnackBar(
        content: Text('Connect & authenticate the band first'),
      ));
      return;
    }
    // Fire-and-forget; the session logs MB6TEST banners to the Debug Log.
    bleManager.runHardwareTestSession();
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const DebugConsole()),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Band Status Card
// ──────────────────────────────────────────────────────────────────────────────

class _BandStatusCard extends StatelessWidget {
  final BLEManager bleManager;
  const _BandStatusCard({required this.bleManager});

  @override
  Widget build(BuildContext context) {
    final connected = bleManager.isConnected;
    final authState = bleManager.authState;
    final device = bleManager.device;
    final battery = bleManager.batteryLevel;

    String authLabel;
    Color authColor;
    switch (authState) {
      case AuthState.authenticating:
        authLabel = 'Authenticating…';
        authColor = Colors.orange;
        break;
      case AuthState.authenticated:
        authLabel = 'Authenticated';
        authColor = Colors.green;
        break;
      case AuthState.failed:
        authLabel = 'Failed';
        authColor = Colors.red;
        break;
      default:
        authLabel = 'Not Authenticated';
        authColor = Colors.grey;
    }

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: const Color(0xFF1A1A2E),
        border: Border.all(
          color: connected
              ? Colors.green.withOpacity(0.3)
              : Colors.white.withOpacity(0.08),
        ),
      ),
      child: Column(
        children: [
          // ── Top row: name + battery ──────────────────────────────
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.07),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.watch, color: Colors.white70, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      device?.platformName.isNotEmpty == true
                          ? device!.platformName
                          : 'Mi Band',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (device != null)
                      Text(
                        device.remoteId.str,
                        style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 11,
                        ),
                      ),
                  ],
                ),
              ),
              if (battery != null)
                _BatteryWidget(level: battery)
              else if (connected)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white38),
                ),
            ],
          ),

          const SizedBox(height: 16),
          Divider(color: Colors.white.withOpacity(0.07), height: 1),
          const SizedBox(height: 16),

          // ── Status rows ──────────────────────────────────────────
          Row(
            children: [
              Expanded(
                child: _StatusPill(
                  label: 'Connection',
                  value: connected ? 'Connected' : 'Disconnected',
                  color: connected ? Colors.green : Colors.red,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _StatusPill(
                  label: 'Auth',
                  value: authLabel,
                  color: authColor,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _StatusPill({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: color.withOpacity(0.7),
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _BatteryWidget extends StatelessWidget {
  final int level;
  const _BatteryWidget({required this.level});

  @override
  Widget build(BuildContext context) {
    final color = level > 50
        ? Colors.green
        : level > 20
            ? Colors.orange
            : Colors.red;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          level > 80
              ? Icons.battery_full
              : level > 50
                  ? Icons.battery_4_bar
                  : level > 20
                      ? Icons.battery_2_bar
                      : Icons.battery_1_bar,
          color: color,
          size: 20,
        ),
        const SizedBox(width: 2),
        Text(
          '$level%',
          style: TextStyle(
            color: color,
            fontSize: 13,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Shared widgets
// ──────────────────────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: Theme.of(context).colorScheme.primary.withOpacity(0.85),
          letterSpacing: 1.4,
        ),
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;
  final String title;
  final Color? titleColor;
  final String? subtitle;
  final Color? subtitleColor;
  final VoidCallback onTap;

  const _SettingsTile({
    required this.icon,
    this.iconColor,
    required this.title,
    this.titleColor,
    this.subtitle,
    this.subtitleColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 2),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(14),
      ),
      child: ListTile(
        leading: Icon(icon, color: iconColor ?? Colors.white60, size: 22),
        title: Text(
          title,
          style: TextStyle(
            color: titleColor ?? Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
        ),
        subtitle: subtitle != null
            ? Text(
                subtitle!,
                style: TextStyle(
                  color: subtitleColor ?? Colors.white38,
                  fontSize: 12,
                ),
              )
            : null,
        trailing:
            const Icon(Icons.chevron_right, color: Colors.white24, size: 20),
        onTap: onTap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );
  }
}
