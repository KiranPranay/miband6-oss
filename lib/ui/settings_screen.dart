import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/auth_manager.dart';
import '../core/ble_manager.dart';
import 'device_scan_screen.dart';
import 'auth_key_screen.dart';
import 'debug_console.dart';
import 'notifications_screen.dart';
import 'theme/tokens.dart';
import 'theme/app_theme.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final authManager = context.watch<AuthManager>();
    final bleManager = context.watch<BLEManager>();

    return Scaffold(
      backgroundColor: AppColors.scaffold,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(
          'Settings',
          style: AppText.h1,
        ),
        iconTheme: const IconThemeData(color: AppColors.ink),
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
              iconColor: AppColors.danger,
              title: 'Disconnect',
              titleColor: AppColors.danger,
              subtitle: 'Stops auto-reconnect',
              onTap: () => bleManager.disconnect(),
            ),

          const SizedBox(height: 8),

          // ── Notifications ────────────────────────────────────────────
          _SectionHeader(title: 'Alerts'),
          _SettingsTile(
            icon: Icons.notifications_active_outlined,
            iconColor: AppColors.spo2,
            title: 'Notifications',
            subtitle: 'Forward calls, messages & app alerts to the band',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const NotificationsScreen()),
            ),
          ),

          const SizedBox(height: 8),

          // ── Auth ──────────────────────────────────────────────────────
          _SectionHeader(title: 'Authentication'),
          _SettingsTile(
            icon: Icons.key_rounded,
            title: 'Auth Key',
            subtitle: authManager.hasKey ? 'Key is set ✓' : 'No key set',
            subtitleColor:
                authManager.hasKey ? AppColors.success : AppColors.warning,
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
                ? AppColors.warning
                : AppColors.activity,
            onTap: () => _onRunHardwareTest(context, bleManager),
          ),
          _SettingsTile(
            icon: Icons.notifications_active_outlined,
            title: 'Send Test Notification',
            subtitle: 'Push a test alert to the band',
            iconColor: AppColors.spo2,
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
        authColor = AppColors.warning;
        break;
      case AuthState.authenticated:
        authLabel = 'Authenticated';
        authColor = AppColors.success;
        break;
      case AuthState.failed:
        authLabel = 'Failed';
        authColor = AppColors.danger;
        break;
      default:
        authLabel = 'Not Authenticated';
        authColor = AppColors.inkMuted;
    }

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadii.lg),
        color: AppColors.surface,
        boxShadow: AppShadows.card,
        border: Border.all(
          color: connected
              ? AppColors.success.withValues(alpha: 0.3)
              : AppColors.divider,
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
                  color: AppColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.watch,
                    color: AppColors.inkMuted, size: 24),
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
                        color: AppColors.ink,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (device != null)
                      Text(
                        device.remoteId.str,
                        style: const TextStyle(
                          color: AppColors.inkFaint,
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
                      strokeWidth: 2, color: AppColors.inkFaint),
                ),
            ],
          ),

          const SizedBox(height: 16),
          const Divider(color: AppColors.divider, height: 1),
          const SizedBox(height: 16),

          // ── Status rows ──────────────────────────────────────────
          Row(
            children: [
              Expanded(
                child: _StatusPill(
                  label: 'Connection',
                  value: connected ? 'Connected' : 'Disconnected',
                  color: connected ? AppColors.success : AppColors.danger,
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
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: color.withValues(alpha: 0.7),
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
        ? AppColors.success
        : level > 20
            ? AppColors.warning
            : AppColors.danger;

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
          color: AppColors.primary.withValues(alpha: 0.85),
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
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        boxShadow: AppShadows.card,
      ),
      child: ListTile(
        leading: Icon(icon, color: iconColor ?? AppColors.inkMuted, size: 22),
        title: Text(
          title,
          style: TextStyle(
            color: titleColor ?? AppColors.ink,
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
        ),
        subtitle: subtitle != null
            ? Text(
                subtitle!,
                style: TextStyle(
                  color: subtitleColor ?? AppColors.inkFaint,
                  fontSize: 12,
                ),
              )
            : null,
        trailing: const Icon(Icons.chevron_right,
            color: AppColors.inkFaint, size: 20),
        onTap: onTap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );
  }
}
