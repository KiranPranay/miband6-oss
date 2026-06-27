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

/// The hero "Today" dashboard: greeting + connection status, a pulsing live
/// heart-rate ring with a measure/stop control, the day's key stats, a steps
/// goal progress bar and a last-synced footer. Pull-to-refresh triggers a
/// one-shot HR measurement.
class TodayTab extends StatefulWidget {
  /// Switches the bottom-nav to the given tab index (1=Heart, 2=Activity,
  /// 3=Sleep) so the summary cards can deep-link into the detail screens.
  final void Function(int index)? onNavigate;

  const TodayTab({super.key, this.onNavigate});

  @override
  State<TodayTab> createState() => _TodayTabState();
}

/// Bottom-nav indices for the detail tabs (see HomeShell).
const int _heartTab = 1;
const int _activityTab = 2;
const int _sleepTab = 3;

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
    final spo2Readings = store.spo2Readings;
    final spo2Last = spo2Readings.isNotEmpty ? spo2Readings.last.value : null;
    final summary = DailySummary.compute(
      sleep: sleep,
      heart: heart,
      activity: activity,
      now: now,
      spo2: spo2Last,
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

                  // --- Personalized briefing ---
                  if (summary.briefing.isNotEmpty) ...[
                    _BriefingCard(lines: summary.briefing),
                    const SizedBox(height: AppSpacing.lg),
                  ],

                  // --- Today's aggregated insights ---
                  if (summary.insights.isNotEmpty) ...[
                    const SectionHeader("Today's insights"),
                    _TodayInsightsCard(insights: summary.insights),
                    const SizedBox(height: AppSpacing.lg),
                  ],

                  // --- Linked summary cards (salience-ordered) ---
                  const SectionHeader('Your day'),
                  _buildSummaryCards(summary.cards),
                  // Gated-trends note: personal comparisons need post-fix history.
                  if (!activity.hasPersonalBaseline) ...[
                    const SizedBox(height: AppSpacing.md),
                    _TrendNote(
                        count: activity.baselineDayCount,
                        needed: activity.baselineDaysNeeded),
                  ],
                  const SizedBox(height: AppSpacing.lg),

                  // --- Goals (real goals only — no hydration / invented goals) ---
                  const SectionHeader('Goals'),
                  _buildGoals(activity, sleep),
                  const SizedBox(height: AppSpacing.lg),

                  // --- Band status ---
                  _WatchStatusCard(
                    connected: ble.isConnected,
                    battery: ble.batteryLevel,
                    lastSync: _relativeSync(ble.lastSyncTime),
                  ),
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
                Text(
                  greeting,
                  style: AppText.h1,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                // Connection detail now lives in the informative band-status card.
                Text(_dateLine(now), style: AppText.label),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Linked summary cards — glanceable summary + tap-through to the detail tab.
  // (Today = summary + navigation; the detail tabs hold the depth.)
  // ---------------------------------------------------------------------------

  IconData _domainIcon(TodayDomain d) {
    switch (d) {
      case TodayDomain.sleep:
        return Icons.bedtime_rounded;
      case TodayDomain.activity:
        return Icons.directions_walk_rounded;
      case TodayDomain.heart:
        return Icons.favorite_rounded;
      case TodayDomain.spo2:
        return Icons.water_drop_rounded;
    }
  }

  int? _domainTab(TodayDomain d) {
    switch (d) {
      case TodayDomain.sleep:
        return _sleepTab;
      case TodayDomain.activity:
        return _activityTab;
      case TodayDomain.heart:
        return _heartTab;
      case TodayDomain.spo2:
        return null; // no dedicated detail tab
    }
  }

  /// Renders the engine's salience-ordered cards (dynamic priority).
  Widget _buildSummaryCards(List<TodayCard> cards) {
    final nav = widget.onNavigate;
    final children = <Widget>[];
    for (var i = 0; i < cards.length; i++) {
      if (i > 0) children.add(const SizedBox(height: AppSpacing.md));
      final c = cards[i];
      final tab = _domainTab(c.domain);
      children.add(_SummaryCard(
        domain: c.domain,
        icon: _domainIcon(c.domain),
        title: c.title,
        value: c.value,
        trend: c.trend,
        trendDir: c.trendDir,
        trendGood: c.trendGood,
        onTap: (!c.navigable || nav == null || tab == null)
            ? null
            : () => nav(tab),
      ));
    }
    return Column(children: children);
  }

  // ---------------------------------------------------------------------------
  // Goals — real, configured goals only (steps + sleep). No invented goals.
  // ---------------------------------------------------------------------------

  Widget _buildGoals(ActivityAnalysis activity, SleepAnalysis? sleep) {
    final reduced = AppMotion.reduced(context);
    return AppCard(
      child: Column(
        children: [
          _GoalBar(
            icon: Icons.directions_walk_rounded,
            color: AppColors.activity,
            label: 'Steps',
            pct: activity.dailyGoalPct, // true, unclamped
            detail:
                '${_formatThousands(activity.todaySteps)} / ${_formatThousands(activity.dailyGoal)}',
            reduced: reduced,
          ),
          if (sleep != null) ...[
            const Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
              child: Divider(height: 1, color: AppColors.divider),
            ),
            _GoalBar(
              icon: Icons.bedtime_rounded,
              color: AppColors.sleep,
              label: 'Sleep',
              pct: sleep.goalPct,
              detail:
                  '${sleep.durationMin ~/ 60}h ${sleep.durationMin % 60}m / ${sleep.goalMin ~/ 60}h',
              reduced: reduced,
            ),
          ],
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

/// A glanceable per-domain summary that links into its detail tab.
class _SummaryCard extends StatelessWidget {
  final TodayDomain domain;
  final IconData icon;
  final String title;
  final String value;
  final String? trend;
  final int trendDir;
  final bool trendGood;
  final VoidCallback? onTap;
  const _SummaryCard({
    required this.domain,
    required this.icon,
    required this.title,
    required this.value,
    required this.onTap,
    this.trend,
    this.trendDir = 0,
    this.trendGood = true,
  });

  @override
  Widget build(BuildContext context) {
    final color = _domainColor(domain);
    final trendColor = trendGood ? AppColors.success : AppColors.warning;
    return AppCard(
      onTap: onTap,
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppText.label),
                const SizedBox(height: 2),
                Text(value,
                    style: AppText.title.copyWith(color: AppColors.ink),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                if (trend != null) ...[
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(
                          trendDir >= 0
                              ? Icons.arrow_upward_rounded
                              : Icons.arrow_downward_rounded,
                          size: 13,
                          color: trendColor),
                      const SizedBox(width: 2),
                      Text(trend!,
                          style:
                              AppText.caption.copyWith(color: trendColor)),
                    ],
                  ),
                ],
              ],
            ),
          ),
          if (onTap != null)
            const Icon(Icons.chevron_right_rounded,
                color: AppColors.inkFaint, size: 22),
        ],
      ),
    );
  }
}

/// A labelled goal progress bar (Steps / Sleep). % is true/unclamped.
class _GoalBar extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final int pct;
  final String detail;
  final bool reduced;
  const _GoalBar({
    required this.icon,
    required this.color,
    required this.label,
    required this.pct,
    required this.detail,
    required this.reduced,
  });

  @override
  Widget build(BuildContext context) {
    final progress = (pct / 100).clamp(0.0, 1.0); // bar caps; number doesn't
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(width: AppSpacing.sm),
            Expanded(child: Text(label, style: AppText.title)),
            Text('$pct%', style: AppText.title.copyWith(color: color)),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadii.pill),
          child: SizedBox(
            height: 10,
            child: Stack(children: [
              Container(color: AppColors.surfaceAlt),
              FractionallySizedBox(
                widthFactor: progress,
                child: reduced
                    ? Container(color: color)
                    : AnimatedContainer(
                        duration: AppMotion.slow,
                        curve: AppMotion.ease,
                        color: color),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 6),
        Text(detail, style: AppText.label),
      ],
    );
  }
}

/// Building-baseline note — explains why personal trends aren't shown yet.
class _TrendNote extends StatelessWidget {
  final int count;
  final int needed;
  const _TrendNote({required this.count, required this.needed});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.insights_rounded, size: 14, color: AppColors.inkFaint),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            'Building your baseline · $count of $needed days — personal trends '
            'unlock then.',
            style: AppText.caption.copyWith(color: AppColors.inkMuted),
          ),
        ),
      ],
    );
  }
}

/// Informative band status block (connection · battery · last sync).
class _WatchStatusCard extends StatelessWidget {
  final bool connected;
  final int? battery;
  final String lastSync;
  const _WatchStatusCard({
    required this.connected,
    required this.battery,
    required this.lastSync,
  });

  @override
  Widget build(BuildContext context) {
    final color = connected ? AppColors.success : AppColors.inkFaint;
    final batteryLow = battery != null && battery! <= 20;
    return AppCard(
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              connected
                  ? Icons.watch_rounded
                  : Icons.bluetooth_disabled_rounded,
              color: color,
              size: 20,
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(connected ? 'Band connected' : 'Band disconnected',
                    style: AppText.title),
                const SizedBox(height: 2),
                Text(
                  connected
                      ? 'Battery ${battery ?? '--'}% · Synced $lastSync'
                      : 'Last synced $lastSync',
                  style: AppText.caption.copyWith(color: AppColors.inkMuted),
                ),
              ],
            ),
          ),
          if (connected)
            Icon(
              batteryLow
                  ? Icons.battery_alert_rounded
                  : Icons.battery_full_rounded,
              color: batteryLow ? AppColors.danger : AppColors.success,
              size: 20,
            ),
        ],
      ),
    );
  }
}

/// Personalized, data-driven briefing lines ("You slept 8h 21m", …).
class _BriefingCard extends StatelessWidget {
  final List<String> lines;
  const _BriefingCard({required this.lines});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < lines.length; i++) ...[
            if (i > 0) const SizedBox(height: AppSpacing.sm),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  margin: const EdgeInsets.only(top: 5),
                  width: 6,
                  height: 6,
                  decoration: const BoxDecoration(
                      color: AppColors.primary, shape: BoxShape.circle),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text(lines[i],
                      style: AppText.body.copyWith(color: AppColors.ink)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Aggregated insights from the three engines, colored by domain.
class _TodayInsightsCard extends StatelessWidget {
  final List<TodayInsight> insights;
  const _TodayInsightsCard({required this.insights});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < insights.length; i++) ...[
            if (i > 0) const SizedBox(height: AppSpacing.sm),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  insights[i].good
                      ? Icons.check_circle_rounded
                      : Icons.info_rounded,
                  size: 18,
                  color: insights[i].good
                      ? AppColors.success
                      : AppColors.warning,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(insights[i].text,
                      style: AppText.body.copyWith(color: AppColors.ink)),
                ),
                const SizedBox(width: AppSpacing.sm),
                Container(
                  width: 6,
                  height: 6,
                  margin: const EdgeInsets.only(top: 6),
                  decoration: BoxDecoration(
                      color: _domainColor(insights[i].domain),
                      shape: BoxShape.circle),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
