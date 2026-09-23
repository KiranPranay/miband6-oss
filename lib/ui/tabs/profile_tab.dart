import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/ble_manager.dart';

import '../stress_screen.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/app_card.dart';
import '../widgets/section_header.dart';
import '../widgets/tab_header.dart';
import '../widgets/settings_widgets.dart';

import '../settings_screen.dart';
import '../sleep_audio/snore_tracking_screen.dart';

/// Profile / Device screen: identity header, the connected band's status +
/// battery + sync, a list of feature shortcuts, and an about card.
class ProfileTab extends StatelessWidget {
  const ProfileTab({super.key});

  @override
  Widget build(BuildContext context) {
    final ble = context.watch<BLEManager>();

    final connected =
        ble.isConnected && ble.authState == AuthState.authenticated;
    final deviceName = (ble.device?.platformName != null &&
            ble.device!.platformName.isNotEmpty)
        ? ble.device!.platformName
        : 'Mi Band 6';

    return CustomScrollView(
      slivers: [
        // 1. Header --------------------------------------------------------
        TabHeaderSliver(
          title: 'Your Band',
          subtitle: deviceName,
          leading: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.primarySoft,
            ),
            child: Icon(Icons.person, color: AppColors.primary, size: 24),
          ),
        ),

        // 2. Device card ---------------------------------------------------
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: _DeviceCard(
              ble: ble,
              connected: connected,
              deviceName: deviceName,
            ),
          ),
        ),

        // 3. Features ------------------------------------------------------
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg, AppSpacing.xl, AppSpacing.lg, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionHeader('Features'),
                GroupCard(children: [
                  NavTile(
                    icon: Icons.mic_rounded,
                    iconColor: AppColors.sleep,
                    title: 'Sleep sounds',
                    subtitle: 'Overnight snoring, from the phone microphone',
                    onTap: () => _push(context, const SnoreTrackingScreen()),
                  ),
                  NavTile(
                    icon: Icons.spa_rounded,
                    iconColor: AppColors.stress,
                    title: 'Stress',
                    subtitle: 'Estimated from heart rate',
                    onTap: () => _push(context, const StressScreen()),
                  ),
                  NavTile(
                    icon: Icons.sync_rounded,
                    iconColor: AppColors.activity,
                    title: 'Sync now',
                    subtitle: 'Pull everything the band has recorded',
                    onTap: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      await ble.syncNow();
                      messenger.showSnackBar(SnackBar(
                        content: Text(ble.isConnected
                            ? 'Synced with your band'
                            : 'Band not connected'),
                      ));
                    },
                  ),
                  NavTile(
                    icon: Icons.tune_rounded,
                    title: 'Settings',
                    subtitle: 'Connection, measurement, display, alerts',
                    onTap: () => _push(context, const SettingsScreen()),
                  ),
                ]),
              ],
            ),
          ),
        ),

        // 4. About ---------------------------------------------------------
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg, AppSpacing.xl, AppSpacing.lg, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionHeader('About'),
                AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 38,
                            height: 38,
                            decoration: BoxDecoration(
                              color: AppColors.primary.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(Icons.watch_rounded,
                                color: AppColors.primary, size: 20),
                          ),
                          const SizedBox(width: AppSpacing.md),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text('Version 1.0.0', style: AppText.title),
                              const SizedBox(height: 2),
                              Text('Band Companion',
                                  style: AppText.caption
                                      .copyWith(color: AppColors.inkMuted)),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.md),
                      Text(
                        'A private companion for your Mi Band 6 — track steps, '
                        'heart rate, sleep and SpO2, all on your device.',
                        style: AppText.body
                            .copyWith(color: AppColors.inkMuted, height: 1.4),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),

        // 5. Bottom spacer (floating nav) ----------------------------------
        const SliverNavClearance(),
      ],
    );
  }

  static void _push(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }
}

/// The device status card: name, connection state, battery bar, last sync and
/// the connect/disconnect action.
class _DeviceCard extends StatelessWidget {
  final BLEManager ble;
  final bool connected;
  final String deviceName;

  const _DeviceCard({
    required this.ble,
    required this.connected,
    required this.deviceName,
  });

  @override
  Widget build(BuildContext context) {
    final authState = ble.authState;

    final String statusText;
    final Color statusColor;
    if (authState == AuthState.authenticated && ble.isConnected) {
      statusText = 'Connected';
      statusColor = AppColors.success;
    } else if (authState == AuthState.authenticating || ble.isAuthenticating) {
      statusText = 'Connecting…';
      statusColor = AppColors.warning;
    } else {
      statusText = 'Disconnected';
      statusColor = AppColors.inkFaint;
    }

    final level = ble.batteryLevel ?? 0;
    final Color batteryColor = level <= 15
        ? AppColors.danger
        : (level <= 35 ? AppColors.warning : AppColors.success);
    final fill = (level / 100).clamp(0.0, 1.0);

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Identity row
          Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  connected
                      ? Icons.bluetooth_connected_rounded
                      : Icons.bluetooth_disabled_rounded,
                  color: statusColor,
                  size: 22,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(deviceName,
                        style: AppText.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text(statusText,
                        style: AppText.label.copyWith(
                            color: statusColor, fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: AppSpacing.lg),

          // Battery row
          Row(
            children: [
              Icon(Icons.battery_full_rounded, size: 18, color: batteryColor),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadii.pill),
                  child: Stack(
                    children: [
                      Container(
                        height: 8,
                        decoration: BoxDecoration(
                          color: AppColors.surfaceAlt,
                          borderRadius: BorderRadius.circular(AppRadii.pill),
                        ),
                      ),
                      FractionallySizedBox(
                        widthFactor: fill,
                        child: Container(
                          height: 8,
                          decoration: BoxDecoration(
                            color: batteryColor,
                            borderRadius: BorderRadius.circular(AppRadii.pill),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Text('${ble.batteryLevel ?? '--'}%',
                  style: AppText.label.copyWith(
                      color: AppColors.ink, fontWeight: FontWeight.w700)),
            ],
          ),

          const SizedBox(height: AppSpacing.md),

          // Last sync line
          Row(
            children: [
              Icon(Icons.sync_rounded, size: 15, color: AppColors.inkFaint),
              const SizedBox(width: AppSpacing.sm),
              Text(
                'Last sync ${_syncLabel(ble.lastSyncTime)}',
                style: AppText.caption.copyWith(color: AppColors.inkMuted),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _syncLabel(DateTime? t) {
    if (t == null) return 'never';
    final diff = DateTime.now().difference(t);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}
