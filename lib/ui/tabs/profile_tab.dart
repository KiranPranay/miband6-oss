import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/ble_manager.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/app_card.dart';
import '../widgets/section_header.dart';

import '../settings_screen.dart';
import '../notifications_screen.dart';
import '../debug_console.dart';
import '../widgets/coming_soon.dart';

/// Profile / Device screen: identity header, the connected band's status +
/// battery + sync, a list of feature shortcuts, and an about card.
class ProfileTab extends StatelessWidget {
  const ProfileTab({super.key});

  @override
  Widget build(BuildContext context) {
    final ble = context.watch<BLEManager>();

    final connected = ble.isConnected && ble.authState == AuthState.authenticated;
    final deviceName = (ble.device?.platformName != null &&
            ble.device!.platformName.isNotEmpty)
        ? ble.device!.platformName
        : 'Mi Band 6';

    return CustomScrollView(
      slivers: [
        // 1. Header --------------------------------------------------------
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg, AppSpacing.xxl, AppSpacing.lg, AppSpacing.lg),
            child: Row(
              children: [
                Container(
                  width: 60,
                  height: 60,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.primarySoft,
                  ),
                  child: const Icon(Icons.person,
                      color: AppColors.primary, size: 32),
                ),
                const SizedBox(width: AppSpacing.lg),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Your Band', style: AppText.h1),
                    const SizedBox(height: 2),
                    Text('Mi Band 6',
                        style: AppText.label
                            .copyWith(color: AppColors.inkMuted)),
                  ],
                ),
              ],
            ),
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
                _FeatureRow(
                  icon: Icons.notifications_rounded,
                  color: AppColors.primary,
                  title: 'Notifications',
                  onTap: () => _push(context, const NotificationsScreen()),
                ),
                const SizedBox(height: AppSpacing.sm),
                _FeatureRow(
                  icon: Icons.spa_rounded,
                  color: AppColors.spo2,
                  title: 'Stress',
                  onTap: () => _push(
                    context,
                    const ComingSoonScreen(
                      title: 'Stress',
                      description:
                          'Continuous stress tracking is coming soon.',
                      icon: Icons.spa_rounded,
                      gradient: [AppColors.spo2, AppColors.primary],
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                _FeatureRow(
                  icon: Icons.auto_awesome_rounded,
                  color: AppColors.primary,
                  title: 'AI Analysis',
                  onTap: () => _push(
                    context,
                    const ComingSoonScreen(
                      title: 'AI Analysis',
                      description:
                          'Personalized AI insights from your health data — coming soon.',
                      icon: Icons.auto_awesome_rounded,
                      gradient: [AppColors.primary, AppColors.heart],
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                _FeatureRow(
                  icon: Icons.settings_rounded,
                  color: AppColors.inkMuted,
                  title: 'Settings',
                  onTap: () => _push(context, const SettingsScreen()),
                ),
                const SizedBox(height: AppSpacing.sm),
                _FeatureRow(
                  icon: Icons.terminal_rounded,
                  color: AppColors.inkMuted,
                  title: 'Debug Console',
                  onTap: () => _push(context, const DebugConsole()),
                ),
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
                              color:
                                  AppColors.primary.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(Icons.watch_rounded,
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
        const SliverToBoxAdapter(child: SizedBox(height: 96)),
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
              Icon(Icons.battery_full_rounded,
                  size: 18, color: batteryColor),
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
                          borderRadius:
                              BorderRadius.circular(AppRadii.pill),
                        ),
                      ),
                      FractionallySizedBox(
                        widthFactor: fill,
                        child: Container(
                          height: 8,
                          decoration: BoxDecoration(
                            color: batteryColor,
                            borderRadius:
                                BorderRadius.circular(AppRadii.pill),
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
              const Icon(Icons.sync_rounded,
                  size: 15, color: AppColors.inkFaint),
              const SizedBox(width: AppSpacing.sm),
              Text(
                'Last sync ${_syncLabel(ble.lastSyncTime)}',
                style: AppText.caption.copyWith(color: AppColors.inkMuted),
              ),
            ],
          ),

          const SizedBox(height: AppSpacing.lg),

          // Action button
          SizedBox(
            width: double.infinity,
            child: connected
                ? OutlinedButton.icon(
                    onPressed: () => ble.disconnect(),
                    icon: const Icon(Icons.link_off_rounded, size: 18),
                    label: const Text('Disconnect'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.danger,
                      side: const BorderSide(color: AppColors.danger),
                      padding: const EdgeInsets.symmetric(
                          vertical: AppSpacing.md),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadii.md),
                      ),
                      textStyle: AppText.label
                          .copyWith(fontWeight: FontWeight.w700),
                    ),
                  )
                : FilledButton.icon(
                    onPressed: () => ble.tryAutoConnect(),
                    icon: const Icon(Icons.bluetooth_rounded, size: 18),
                    label: const Text('Connect'),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                          vertical: AppSpacing.md),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadii.md),
                      ),
                      textStyle: AppText.label.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w700),
                    ),
                  ),
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

/// A tappable settings/feature row: tinted leading icon, title, trailing chevron.
class _FeatureRow extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final VoidCallback onTap;

  const _FeatureRow({
    required this.icon,
    required this.color,
    required this.title,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg, vertical: AppSpacing.md),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(child: Text(title, style: AppText.title)),
          const Icon(Icons.chevron_right,
              color: AppColors.inkFaint, size: 22),
        ],
      ),
    );
  }
}
