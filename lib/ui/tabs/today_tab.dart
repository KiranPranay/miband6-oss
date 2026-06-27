import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/activity_analysis.dart';
import '../../core/activity_sample.dart';
import '../../core/ble_manager.dart';
import '../../core/daily_summary.dart';
import '../../core/heart_analysis.dart';
import '../../core/sleep_analysis.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/app_card.dart';
import '../widgets/count_up_text.dart';
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

  /// Last night's main sleep session (longest non-nap within ~40h of the latest
  /// recorded sleep), mirroring how the Sleep tab selects its session.
  SleepDay? _lastNight(List<SleepDay> days) {
    final ends = days.map((d) => d.endTime).whereType<DateTime>().toList();
    if (ends.isEmpty) return null;
    final latest = ends.reduce((a, b) => a.isAfter(b) ? a : b);
    final cutoff = latest.subtract(const Duration(hours: 40));
    final recent =
        days.where((d) => d.endTime != null && !d.endTime!.isBefore(cutoff));
    final nights = recent.where((d) => !d.isNap).toList();
    final pool = nights.isNotEmpty ? nights : recent.toList();
    if (pool.isEmpty) return null;
    return pool
        .reduce((a, b) => a.totalSleepMinutes >= b.totalSleepMinutes ? a : b);
  }

  @override
  Widget build(BuildContext context) {
    final ble = context.watch<BLEManager>();
    final store = ble.activityStore;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    // Today is a COMPOSITION of the existing engines — no raw re-parsing.
    final allDays = store.computeSleepDays();
    final lastNight = _lastNight(allDays);
    final sleep = lastNight == null
        ? null
        : SleepAnalysis.compute(
            session: lastNight,
            allDays: allDays,
            hr: store.hrReadings,
            spo2: store.spo2Readings,
          );
    final heart = HeartAnalysis.compute(
      currentBpm: ble.heartRate,
      hrReadings: store.hrReadings,
      samples: store.samples,
    );
    final activity = ActivityAnalysis.compute(
      liveSteps: ble.metrics.steps,
      todaySamples: store.samplesForDate(today),
      hourly: store.getStepsByHour(today),
      allSamples: store.samples,
      now: now,
      dailyGoal: _stepsGoal,
    );
    final summary = DailySummary.compute(
      sleep: sleep,
      heart: heart,
      activity: activity,
      now: now,
    );

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

                  // --- Composite Health Score (real sub-scores, breakdown shown) ---
                  _HealthHero(summary: summary),
                  const SizedBox(height: AppSpacing.lg),

                  // --- Stats grid ---
                  const SectionHeader('Stats'),
                  _buildStatsGrid(ble, activity),
                  const SizedBox(height: AppSpacing.lg),

                  // --- Steps goal ---
                  _buildStepsGoal(activity),
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
  // Stats grid
  // ---------------------------------------------------------------------------

  Widget _buildStatsGrid(BLEManager ble, ActivityAnalysis activity) {
    final m = ble.metrics;
    final spo2 = ble.activityStore.spo2Readings;
    final spo2Value = spo2.isNotEmpty ? spo2.last.value : 0;

    final cards = <Widget>[
      StatCard(
        icon: Icons.directions_walk_rounded,
        color: AppColors.activity,
        value: activity.todaySteps, // corrected per-minute total (band counter)
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

  Widget _buildStepsGoal(ActivityAnalysis activity) {
    final steps = activity.todaySteps; // corrected per-minute total
    final progress = (steps / _stepsGoal).clamp(0.0, 1.0);
    final percent = activity.dailyGoalPct; // true, unclamped
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

// ===========================================================================
// Composite Health Score hero — real sub-scores, breakdown always shown.
// ===========================================================================

Color _domainColor(TodayDomain d) {
  switch (d) {
    case TodayDomain.sleep:
      return AppColors.sleep;
    case TodayDomain.activity:
      return AppColors.activity;
    case TodayDomain.heart:
      return AppColors.heart;
    case TodayDomain.spo2:
      return AppColors.spo2;
  }
}

({String word, Color color}) _bandStyle(HealthBand b) {
  switch (b) {
    case HealthBand.excellent:
      return (word: 'Excellent', color: AppColors.success);
    case HealthBand.good:
      return (word: 'Good', color: AppColors.success);
    case HealthBand.fair:
      return (word: 'Fair', color: AppColors.warning);
    case HealthBand.low:
      return (word: 'Low', color: AppColors.danger);
  }
}

class _HealthHero extends StatelessWidget {
  final DailySummary summary;
  const _HealthHero({required this.summary});

  @override
  Widget build(BuildContext context) {
    final score = summary.healthScore;
    if (score == null) {
      // No component has data — never show a fake 0.
      return AppCard(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.insights_rounded,
                  color: AppColors.primary, size: 22),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(
                'Wear and sync your band to see today’s health score.',
                style: AppText.body.copyWith(color: AppColors.inkMuted),
              ),
            ),
          ],
        ),
      );
    }

    final bs = _bandStyle(summary.band!);
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Today', style: AppText.label),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      CountUpText(score,
                          style: AppText.metricHero
                              .copyWith(color: bs.color, fontSize: 46)),
                      const SizedBox(width: 4),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text('/ 100', style: AppText.unit),
                      ),
                    ],
                  ),
                  Pill(bs.word, color: bs.color),
                ],
              ),
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: Text(
                  summary.missing.isEmpty
                      ? 'Based on ${summary.basis.join(' + ')}.'
                      : 'Based on ${summary.basis.join(' + ')} — '
                          '${summary.missing.join(' & ')} not recorded.',
                  style: AppText.caption.copyWith(color: AppColors.inkMuted),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          const Divider(height: 1, color: AppColors.divider),
          const SizedBox(height: AppSpacing.md),
          for (var i = 0; i < summary.components.length; i++) ...[
            if (i > 0) const SizedBox(height: AppSpacing.md),
            _ComponentRow(c: summary.components[i]),
          ],
        ],
      ),
    );
  }
}

class _ComponentRow extends StatelessWidget {
  final HealthComponent c;
  const _ComponentRow({required this.c});

  @override
  Widget build(BuildContext context) {
    final color = _domainColor(c.domain);
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: AppSpacing.sm),
        SizedBox(
          width: 64,
          child: Text(c.label,
              style: AppText.label.copyWith(color: AppColors.ink)),
        ),
        // Real number for Sleep/Activity; Heart shows status only (no number).
        if (c.displayScore != null) ...[
          Text('${c.displayScore}',
              style: AppText.title.copyWith(color: color)),
          const SizedBox(width: AppSpacing.sm),
        ] else ...[
          const Text('—',
              style: TextStyle(color: AppColors.inkFaint)),
          const SizedBox(width: AppSpacing.sm),
        ],
        Expanded(
          child: Text(c.status,
              textAlign: TextAlign.end,
              style: AppText.caption.copyWith(color: AppColors.inkMuted)),
        ),
      ],
    );
  }
}
