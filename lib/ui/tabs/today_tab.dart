import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/ble_manager.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/app_card.dart';
import '../widgets/count_up_text.dart';
import '../widgets/pulsing_heart_ring.dart';
import '../widgets/section_header.dart';
import '../widgets/stat_card.dart';

/// The hero "Today" dashboard: greeting + connection status, a pulsing live
/// heart-rate ring with a measure/stop control, the day's key stats, a steps
/// goal progress bar and a last-synced footer. Pull-to-refresh triggers a
/// one-shot HR measurement.
class TodayTab extends StatefulWidget {
  const TodayTab({super.key});

  @override
  State<TodayTab> createState() => _TodayTabState();
}

class _TodayTabState extends State<TodayTab> {
  static const int _stepsGoal = 10000;

  Future<void> _onRefresh(BLEManager ble) async {
    try {
      await ble.measureHeartRateOnce();
    } catch (_) {
      // Band may be disconnected — refresh should still complete gracefully.
    }
    await Future.delayed(const Duration(milliseconds: 600));
  }

  String _greeting(int hour) {
    if (hour < 12) return 'Good morning';
    if (hour < 17) return 'Good afternoon';
    return 'Good evening';
  }

  static const List<String> _weekdays = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];
  static const List<String> _months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];

  String _dateLine(DateTime now) {
    // e.g. "Wednesday, 25 June"
    return '${_weekdays[now.weekday - 1]}, ${now.day} ${_months[now.month - 1]}';
  }

  String _relativeSync(DateTime? t) {
    if (t == null) return 'Never';
    final diff = DateTime.now().difference(t);
    if (diff.inSeconds < 45) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  @override
  Widget build(BuildContext context) {
    final ble = context.watch<BLEManager>();

    return RefreshIndicator(
      onRefresh: () => _onRefresh(ble),
      color: AppColors.primary,
      backgroundColor: AppColors.surface,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          _buildHeader(ble),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: AppSpacing.sm),

                  // --- Heart rate ---
                  const SectionHeader('Heart rate'),
                  _buildHeartRate(ble),
                  const SizedBox(height: AppSpacing.lg),

                  // --- Stats grid ---
                  const SectionHeader('Stats'),
                  _buildStatsGrid(ble),
                  const SizedBox(height: AppSpacing.lg),

                  // --- Steps goal ---
                  _buildStepsGoal(ble),
                  const SizedBox(height: AppSpacing.lg),

                  // --- Last synced ---
                  _buildLastSynced(ble),
                ],
              ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 96)),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Collapsing header
  // ---------------------------------------------------------------------------

  Widget _buildHeader(BLEManager ble) {
    final now = DateTime.now();
    final greeting = _greeting(now.hour);

    return SliverAppBar(
      pinned: true,
      expandedHeight: 156,
      backgroundColor: AppColors.scaffold,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      automaticallyImplyLeading: false,
      flexibleSpace: FlexibleSpaceBar(
        background: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.lg,
              AppSpacing.lg,
              AppSpacing.md,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Spacer(),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            greeting,
                            style: AppText.h1,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(_dateLine(now), style: AppText.label),
                        ],
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    _buildConnectionStatus(ble),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildConnectionStatus(BLEManager ble) {
    if (!ble.isConnected) {
      return const Pill(
        'Disconnected',
        color: AppColors.inkFaint,
        icon: Icons.bluetooth_disabled,
      );
    }

    final level = ble.batteryLevel;
    final batteryColor =
        (level != null && level > 20) ? AppColors.success : AppColors.danger;
    final batteryIcon = (level != null && level > 20)
        ? Icons.battery_full_rounded
        : Icons.battery_alert_rounded;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        const Pill(
          'Connected',
          color: AppColors.success,
          icon: Icons.bluetooth_connected,
        ),
        const SizedBox(height: AppSpacing.xs),
        Pill(
          '${level ?? '--'}%',
          color: batteryColor,
          icon: batteryIcon,
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Heart rate
  // ---------------------------------------------------------------------------

  Widget _buildHeartRate(BLEManager ble) {
    final active = ble.isRealtimeHeartRateActive;
    return AppCard(
      child: Column(
        children: [
          Center(
            child: PulsingHeartRing(
              bpm: ble.heartRate,
              measuring: active,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          _HeartButton(
            active: active,
            onPressed: () {
              if (active) {
                ble.stopRealtimeHeartRate();
              } else {
                ble.startRealtimeHeartRate();
              }
            },
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Stats grid
  // ---------------------------------------------------------------------------

  Widget _buildStatsGrid(BLEManager ble) {
    final m = ble.metrics;
    final spo2 = ble.activityStore.spo2Readings;
    final spo2Value = spo2.isNotEmpty ? spo2.last.value : 0;

    final cards = <Widget>[
      StatCard(
        icon: Icons.directions_walk_rounded,
        color: AppColors.activity,
        value: m.steps,
        label: 'Steps',
      ),
      StatCard(
        icon: Icons.straighten_rounded,
        color: AppColors.distance,
        value: m.distanceMeters / 1000,
        decimals: 2,
        unit: 'km',
        label: 'Distance',
      ),
      StatCard(
        icon: Icons.local_fire_department_rounded,
        color: AppColors.calories,
        value: m.calories,
        unit: 'kcal',
        label: 'Calories',
      ),
      StatCard(
        icon: Icons.water_drop_rounded,
        color: AppColors.spo2,
        value: spo2Value,
        unit: '%',
        label: 'SpO2',
      ),
    ];

    // Two-column grid via Row/Expanded — flex distributes the available width
    // safely (no manual width math that could go negative under transient
    // constraints, which previously crashed layout).
    return Column(
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: cards[0]),
            const SizedBox(width: AppSpacing.md),
            Expanded(child: cards[1]),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: cards[2]),
            const SizedBox(width: AppSpacing.md),
            Expanded(child: cards[3]),
          ],
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Steps goal
  // ---------------------------------------------------------------------------

  Widget _buildStepsGoal(BLEManager ble) {
    final steps = ble.metrics.steps;
    final progress = (steps / _stepsGoal).clamp(0.0, 1.0);
    final percent = (progress * 100).round();
    final reduced = AppMotion.reduced(context);

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: AppColors.activity.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.flag_rounded,
                  color: AppColors.activity,
                  size: 20,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(child: Text('Steps goal', style: AppText.title)),
              Text('$percent%',
                  style: AppText.title.copyWith(color: AppColors.activity)),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadii.pill),
            child: Stack(
              children: [
                Container(
                  height: 12,
                  decoration: BoxDecoration(
                    color: AppColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(AppRadii.pill),
                  ),
                ),
                LayoutBuilder(
                  builder: (context, c) {
                    final w = c.maxWidth * progress;
                    final bar = Container(
                      height: 12,
                      width: w,
                      decoration: BoxDecoration(
                        color: AppColors.activity,
                        borderRadius: BorderRadius.circular(AppRadii.pill),
                      ),
                    );
                    if (reduced) return bar;
                    return AnimatedContainer(
                      duration: AppMotion.slow,
                      curve: AppMotion.ease,
                      height: 12,
                      width: w,
                      decoration: BoxDecoration(
                        color: AppColors.activity,
                        borderRadius: BorderRadius.circular(AppRadii.pill),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              CountUpText(
                steps,
                style: AppText.label.copyWith(color: AppColors.ink),
              ),
              Text(
                ' / ${_formatThousands(_stepsGoal)}',
                style: AppText.label,
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _formatThousands(int v) {
    final s = v.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }

  // ---------------------------------------------------------------------------
  // Last synced
  // ---------------------------------------------------------------------------

  Widget _buildLastSynced(BLEManager ble) {
    return Center(
      child: Text(
        'Last synced ${_relativeSync(ble.lastSyncTime)}',
        style: AppText.caption,
      ),
    );
  }
}

/// Rounded filled heart-coloured button toggling realtime HR.
class _HeartButton extends StatelessWidget {
  final bool active;
  final VoidCallback onPressed;

  const _HeartButton({required this.active, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: active ? AppColors.heartSoft : AppColors.heart,
      borderRadius: BorderRadius.circular(AppRadii.pill),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(AppRadii.pill),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.xxl,
            vertical: AppSpacing.md,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                active ? Icons.stop_rounded : Icons.favorite_rounded,
                size: 18,
                color: active ? AppColors.heart : Colors.white,
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                active ? 'Stop' : 'Measure',
                style: AppText.label.copyWith(
                  color: active ? AppColors.heart : Colors.white,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
