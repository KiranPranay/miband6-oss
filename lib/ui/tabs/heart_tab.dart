import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:provider/provider.dart';

import '../../core/analysis_cache.dart';
import '../../core/ble_manager.dart';
import '../../core/activity_sample.dart';
import '../../core/heart_analysis.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../stress_screen.dart';
import '../widgets/app_card.dart';
import '../widgets/chart_card.dart';
import '../widgets/pulsing_heart_ring.dart';
import '../widgets/section_header.dart';
import '../widgets/ledger.dart';
import '../widgets/tab_header.dart';
import '../widgets/segmented_toggle.dart';

/// The Heart screen — a heart-health view, not a bare sensor dashboard: a hero
/// leading with status + resting HR + trend, rule-based insights, a referenced
/// trend chart, and (gated) personal comparisons. Stress lives on its own
/// screen; the band's own stress stream is quarantined because what it returns
/// does not decode as stress (findings-23), so what is shown is estimated from
/// heart rate and labelled as such. Recovery stays omitted because it needs
/// HRV, which this firmware does not report.
///
/// Colour roles: pink = live heart data, purple = trends/resting, green =
/// healthy status, amber = warnings.
class HeartTab extends StatefulWidget {
  const HeartTab({super.key});

  @override
  State<HeartTab> createState() => _HeartTabState();
}

class _HeartTabState extends State<HeartTab> {
  int _range = 0; // 0 = Today, 1 = Week, 2 = Month

  List<HeartRateReading> _filtered(List<HeartRateReading> all) {
    if (all.isEmpty) return const [];
    final now = DateTime.now();
    if (_range == 0) {
      final today = DateTime(now.year, now.month, now.day);
      final tomorrow = today.add(const Duration(days: 1));
      return all
          .where((r) =>
              !r.timestamp.isBefore(today) && r.timestamp.isBefore(tomorrow))
          .toList();
    }
    final days = _range == 2 ? 29 : 6; // Week = last 7 days, Month = last 30
    final cutoff =
        DateTime(now.year, now.month, now.day).subtract(Duration(days: days));
    return all.where((r) => !r.timestamp.isBefore(cutoff)).toList();
  }

  /// Only offer ranges that have real data behind them (honesty over polish):
  /// "Month" appears only when readings actually span beyond a week.
  List<String> _ranges(List<HeartRateReading> all) {
    if (all.isEmpty) return const ['Today', 'Week'];
    final now = DateTime.now();
    final weekAgo = DateTime(now.year, now.month, now.day)
        .subtract(const Duration(days: 7));
    final hasOlder = all.any((r) => r.timestamp.isBefore(weekAgo));
    return hasOlder
        ? const ['Today', 'Week', 'Month']
        : const ['Today', 'Week'];
  }

  @override
  Widget build(BuildContext context) {
    final ble = context.read<BLEManager>();
    // Live HR is the point of this screen, so it *is* in the subscription set —
    // but the analysis below is memoised against the store revision, so a beat
    // costs a widget rebuild instead of a full pass over stored history.
    return ListenableBuilder(
      listenable: Listenable.merge([
        ble.activityStore.revisionListenable,
        ble.authStateListenable,
        ble.heartRateListenable,
        ble.realtimeHrListenable,
      ]),
      builder: (context, _) => _buildContent(context, ble),
    );
  }

  Widget _buildContent(BuildContext context, BLEManager ble) {
    final store = ble.activityStore;
    final ranges = _ranges(store.hrReadings);
    if (_range >= ranges.length) _range = ranges.length - 1;
    final readings = _filtered(store.hrReadings);
    final isActive = ble.isRealtimeHeartRateActive;
    final heart = AnalysisCache.heart(store, currentBpm: ble.heartRate);

    return CustomScrollView(
      slivers: [
        _buildAppBar(ble),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: AppSpacing.sm),
                _HeartHero(
                  heart: heart,
                  measuring: isActive,
                  onToggle: () => isActive
                      ? ble.stopRealtimeHeartRate()
                      : ble.startRealtimeHeartRate(),
                ),
                const SizedBox(height: AppSpacing.lg),
                _InsightsCard(insights: heart.insights),
                SectionHeader(
                  'Trend',
                  trailing: SegmentedToggle(
                    options: ranges,
                    index: _range,
                    accent: AppColors.heart,
                    onChanged: (i) => setState(() => _range = i),
                  ),
                ),
                ChartCard(
                  title: 'Heart rate',
                  subtitle: _range == 0
                      ? 'Today'
                      : (_range == 1 ? 'Last 7 days' : 'Last 30 days'),
                  height: 220,
                  child: _HeartRateChart(
                    readings: readings,
                    week: _range >= 1,
                    zones: heart.zones,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                const _ZoneLegend(),
                const SizedBox(height: AppSpacing.lg),
                _SummaryLedger(
                    readings: readings,
                    week: _range >= 1,
                    highest: _range == 0 ? heart.highest : null),
                if (_range == 1) ...[
                  const SectionHeader('This week'),
                  _WeekSummaryCard(heart: heart),
                ],
                const SectionHeader('Recommendations'),
                _RecommendationsCard(items: heart.recommendations),
                const SectionHeader('More heart metrics'),
                const _MoreMetricsCard(),
              ],
            ),
          ),
        ),
        const SliverNavClearance(),
      ],
    );
  }

  Widget _buildAppBar(BLEManager ble) {
    final live = ble.heartRate;
    final store = ble.activityStore;
    final bpm =
        live ?? (store.hrReadings.isEmpty ? null : store.hrReadings.last.value);
    final isLive = live != null;
    return TabHeaderSliver(
      title: 'Heart',
      subtitle:
          bpm == null ? '-- BPM' : (isLive ? '$bpm BPM now' : '$bpm BPM last'),
      subtitleIcon: Icons.favorite_rounded,
      subtitleIconColor: AppColors.heart,
    );
  }
}

// ===========================================================================
// Hero — status + resting prominence + trend (not a bare number)
// ===========================================================================

Color _zoneColor(String label) {
  switch (label) {
    case 'Resting':
      return AppColors.sleep;
    case 'Elevated':
      return AppColors.warning;
    default: // Normal
      return AppColors.success;
  }
}

Color _statusColor(HrStatus s) {
  switch (s) {
    case HrStatus.normal:
      return AppColors.success;
    case HrStatus.elevated:
      return AppColors.warning;
    case HrStatus.low:
      return AppColors.sleep;
  }
}

String _statusLabel(HrStatus s) {
  switch (s) {
    case HrStatus.normal:
      return 'Normal';
    case HrStatus.elevated:
      return 'Elevated';
    case HrStatus.low:
      return 'Low';
  }
}

({String text, IconData icon, Color color}) _trendChip(HrTrend t) {
  switch (t) {
    case HrTrend.stable:
      return (
        text: 'Stable',
        icon: Icons.trending_flat_rounded,
        color: AppColors.sleep
      );
    case HrTrend.rising:
      return (
        text: 'Rising',
        icon: Icons.trending_up_rounded,
        color: AppColors.warning
      );
    case HrTrend.falling:
      return (
        text: 'Easing',
        icon: Icons.trending_down_rounded,
        color: AppColors.sleep
      );
    case HrTrend.unknown:
      return (
        text: 'Building data',
        icon: Icons.more_horiz_rounded,
        color: AppColors.inkFaint
      );
  }
}

class _HeartHero extends StatelessWidget {
  final HeartAnalysis heart;
  final bool measuring;
  final VoidCallback onToggle;
  const _HeartHero(
      {required this.heart, required this.measuring, required this.onToggle});

  /// "18 min ago" / "2 h ago" for the last recorded reading.
  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours} h ago';
    return '${d.inDays} d ago';
  }

  @override
  Widget build(BuildContext context) {
    // Fall back to the band's own most recent measurement when the live stream
    // is off. Showing "--" was misleading: the band measures periodically on its
    // own schedule, so there IS a reading, it just is not live.
    final live = heart.currentBpm;
    final isLive = live != null && live > 0;
    final cur = isLive ? live : heart.lastRecordedBpm;
    final status = isLive
        ? heart.currentStatus
        : (cur != null && cur > 0 ? HeartAnalysis.statusOf(cur) : null);
    final recordedAt = heart.lastRecordedAt;
    final tc = _trendChip(heart.trend);

    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              PulsingHeartRing(bpm: cur, size: 116, measuring: measuring),
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(isLive ? 'Current' : 'Last recorded',
                            style: AppText.label),
                        if (measuring) ...[
                          const SizedBox(width: AppSpacing.sm),
                          _LiveBadge(),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(cur != null && cur > 0 ? '$cur' : '--',
                            style: AppText.metric
                                .copyWith(color: AppColors.heart)),
                        const SizedBox(width: 4),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 3),
                          child: Text('bpm', style: AppText.unit),
                        ),
                        if (status != null) ...[
                          const SizedBox(width: AppSpacing.sm),
                          _Pill(
                              text: _statusLabel(status),
                              color: _statusColor(status)),
                        ],
                      ],
                    ),
                    if (!isLive && cur != null && recordedAt != null) ...[
                      const SizedBox(height: 2),
                      Text('measured by your band · ${_ago(recordedAt)}',
                          style: AppText.caption
                              .copyWith(color: AppColors.inkMuted)),
                    ],
                    const SizedBox(height: AppSpacing.sm),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(tc.icon, size: 15, color: tc.color),
                        const SizedBox(width: 5),
                        Text('Trend · ${tc.text}',
                            style: AppText.caption.copyWith(color: tc.color)),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          Divider(height: 1, color: AppColors.divider),
          const SizedBox(height: AppSpacing.md),
          // Resting HR gets prominence — it's the health-relevant number.
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppColors.sleep.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.self_improvement_rounded,
                    color: AppColors.sleep, size: 20),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Resting heart rate', style: AppText.title),
                    Text(heart.restingLabel,
                        style: AppText.caption
                            .copyWith(color: AppColors.inkMuted)),
                  ],
                ),
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(heart.restingHr != null ? '${heart.restingHr}' : '--',
                      style: AppText.metric.copyWith(color: AppColors.sleep)),
                  const SizedBox(width: 3),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text('bpm', style: AppText.unit),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          _RealtimeButton(active: measuring, onTap: onToggle),
        ],
      ),
    );
  }
}

class _LiveBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.heart.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadii.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration:
                BoxDecoration(color: AppColors.heart, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text('LIVE',
              style: AppText.caption.copyWith(
                  color: AppColors.heart,
                  fontWeight: FontWeight.w800,
                  fontSize: 10,
                  letterSpacing: 0.5)),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String text;
  final Color color;
  const _Pill({required this.text, required this.color});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadii.pill),
      ),
      child: Text(text,
          style: AppText.caption
              .copyWith(color: color, fontWeight: FontWeight.w700)),
    );
  }
}

class _RealtimeButton extends StatelessWidget {
  final bool active;
  final VoidCallback onTap;
  const _RealtimeButton({required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.pill),
        child: AnimatedContainer(
          duration: AppMotion.fast,
          curve: AppMotion.ease,
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
          decoration: BoxDecoration(
            color: active ? AppColors.heartSoft : AppColors.heart,
            borderRadius: BorderRadius.circular(AppRadii.pill),
            boxShadow: active ? null : AppShadows.glow(AppColors.heart),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(active ? Icons.stop_rounded : Icons.favorite_rounded,
                  size: 18, color: active ? AppColors.heart : Colors.white),
              const SizedBox(width: AppSpacing.sm),
              Text(active ? 'Stop live monitoring' : 'Measure live',
                  style: AppText.label.copyWith(
                      color: active ? AppColors.heart : Colors.white,
                      fontWeight: FontWeight.w800)),
            ],
          ),
        ),
      ),
    );
  }
}

// ===========================================================================
// Insights
// ===========================================================================

class _InsightsCard extends StatelessWidget {
  final List<HeartInsight> insights;
  const _InsightsCard({required this.insights});

  @override
  Widget build(BuildContext context) {
    if (insights.isEmpty) return const SizedBox.shrink();
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.lightbulb_rounded, size: 18, color: AppColors.primary),
              const SizedBox(width: AppSpacing.sm),
              Text('Insights', style: AppText.title),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
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
                  color:
                      insights[i].good ? AppColors.success : AppColors.warning,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(insights[i].text,
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

// ===========================================================================
// Trend chart
// ===========================================================================

class _HeartRateChart extends StatelessWidget {
  final List<HeartRateReading> readings;
  final bool week;
  final List<HrZone> zones;
  const _HeartRateChart(
      {required this.readings, required this.week, required this.zones});

  @override
  Widget build(BuildContext context) {
    if (readings.isEmpty) {
      return const ChartEmpty(
        message: 'No heart-rate history yet',
        icon: Icons.favorite_border_rounded,
      );
    }

    // x is *time*, in minutes from the first reading — not the reading's index.
    //
    // Index-based x silently distorts the axis whenever sampling is uneven,
    // which it always is here: a few minutes of live monitoring produce one
    // reading per second while the rest of the day produces one every few
    // minutes. On a real day that put 00:00–14:55 in the first third of the
    // chart and 14:55–23:43 in the last third, so a flat stretch and a busy one
    // looked equally long. Plotting against the clock makes horizontal distance
    // mean elapsed time, which is the only reading of a trend line anyone
    // actually makes.
    // Today is drawn on a fixed midnight-to-midnight axis, so the chart reads
    // the same at 01:00 as at 23:00 and the eye learns where 6 a.m. is. Week
    // and Month run from the start of their range with a tick per day.
    final first = readings.first.timestamp;
    final t0 = week
        ? DateTime(first.year, first.month, first.day)
        : DateTime(first.year, first.month, first.day);
    double x(DateTime t) => t.difference(t0).inSeconds / 60.0;

    // Don't draw a line across a stretch with no data — an interpolated segment
    // is indistinguishable from a measured one. Break the series instead, so a
    // gap looks like a gap. The threshold sits above the band's own periodic
    // sampling interval, so normal all-day monitoring stays one continuous line.
    final gapMinutes = week ? 6 * 60.0 : 20.0;
    final segments = <List<FlSpot>>[];
    var current = <FlSpot>[];
    for (var i = 0; i < readings.length; i++) {
      if (i > 0 &&
          readings[i]
                  .timestamp
                  .difference(readings[i - 1].timestamp)
                  .inMinutes >
              gapMinutes) {
        if (current.isNotEmpty) segments.add(current);
        current = <FlSpot>[];
      }
      current
          .add(FlSpot(x(readings[i].timestamp), readings[i].value.toDouble()));
    }
    if (current.isNotEmpty) segments.add(current);

    final values = readings.map((r) => r.value).toList();
    final rawMin = values.reduce((a, b) => a < b ? a : b).toDouble();
    final rawMax = values.reduce((a, b) => a > b ? a : b).toDouble();
    final avg = (values.reduce((a, b) => a + b) / values.length);
    // "Nice" y ticks: a step of 10 or 20 bpm, extents rounded to it, so the
    // axis reads 50 · 60 · 70 rather than 52 · 81 · 102.
    final span = (rawMax - rawMin).clamp(20.0, 300.0);
    final yInterval = span > 90 ? 20.0 : 10.0;
    final minV = ((rawMin - 5) / yInterval).floor() * yInterval;
    final maxV = ((rawMax + 5) / yInterval).ceil() * yInterval;
    // Today: full day. Week/Month: whole days from the range start.
    final maxX =
        week ? (x(readings.last.timestamp) / 1440).ceil() * 1440.0 : 1440.0;
    final nowX = week ? null : x(DateTime.now());
    // Today: 6-hour ticks. Week: daily. Month: every 5 days.
    final labelStep = week ? (maxX > 10 * 1440 ? 5 * 1440.0 : 1440.0) : 360.0;

    // Labelled HR-zone bands, each clipped to the visible y-range so only the
    // zones the data actually touches are tinted.
    final bands = <HorizontalRangeAnnotation>[];
    for (final z in zones) {
      final lo = z.low.toDouble().clamp(minV, maxV);
      final hi = z.high.toDouble().clamp(minV, maxV);
      if (hi - lo <= 0.5) continue;
      bands.add(HorizontalRangeAnnotation(
        y1: lo,
        y2: hi,
        color: _zoneColor(z.label).withValues(alpha: 0.11),
      ));
    }

    HorizontalLine marker(double y, Color c, String label) => HorizontalLine(
          y: y,
          color: c.withValues(alpha: 0.55),
          strokeWidth: 1,
          dashArray: const [4, 4],
          label: HorizontalLineLabel(
            show: true,
            // Right edge: on the left these sat on top of the y-axis labels.
            alignment: Alignment.topRight,
            padding: const EdgeInsets.only(right: 4, bottom: 2),
            style: AppText.caption
                .copyWith(color: c, fontSize: 9, fontWeight: FontWeight.w700),
            labelResolver: (_) => label,
          ),
        );

    return LineChart(
      LineChartData(
        minX: 0,
        maxX: maxX,
        minY: minV,
        maxY: maxV,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: yInterval,
          getDrawingHorizontalLine: (_) =>
              FlLine(color: AppColors.divider, strokeWidth: 1),
        ),
        borderData: FlBorderData(show: false),
        rangeAnnotations: RangeAnnotations(horizontalRangeAnnotations: bands),
        extraLinesData: ExtraLinesData(
          horizontalLines: [
            marker(rawMin, AppColors.sleep, 'min'),
            marker(avg, AppColors.inkMuted, 'avg'),
            marker(rawMax, AppColors.heart, 'max'),
          ],
          verticalLines: [
            if (nowX != null)
              VerticalLine(
                x: nowX,
                color: AppColors.inkFaint.withValues(alpha: 0.7),
                strokeWidth: 1,
                dashArray: const [3, 3],
                label: VerticalLineLabel(
                  show: true,
                  alignment: Alignment.topRight,
                  style: AppText.caption
                      .copyWith(color: AppColors.inkFaint, fontSize: 9),
                  labelResolver: (_) => 'now',
                ),
              ),
          ],
        ),
        titlesData: FlTitlesData(
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 30,
              interval: yInterval,
              getTitlesWidget: (value, meta) {
                // fl_chart emits a title at the axis minimum as well as at each
                // interval step. When the two land within a line-height of each
                // other they overprint — the live chart was showing "52" and
                // "50" stacked on top of one another, unreadable. Drop a label
                // that is too close to the axis edge to stand alone.
                final tooCloseToEdge =
                    (value - meta.min).abs() < yInterval * 0.5 ||
                        (meta.max - value).abs() < yInterval * 0.5;
                if (tooCloseToEdge && value != meta.min) {
                  return const SizedBox.shrink();
                }
                return Text(
                  value.round().toString(),
                  style: AppText.caption.copyWith(color: AppColors.inkFaint),
                );
              },
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 22,
              interval: labelStep <= 0 ? 1 : labelStep,
              getTitlesWidget: (value, meta) {
                // x is minutes from the axis origin (midnight, or the range
                // start), so a label is that offset added back on.
                final t = t0.add(Duration(seconds: (value * 60).round()));
                String text;
                if (week) {
                  const wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
                  text = maxX > 10 * 1440 ? '${t.day}' : wd[t.weekday - 1];
                } else {
                  // 12a · 6a · 12p · 6p · 12a
                  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
                  text = '$h${t.hour < 12 ? 'a' : 'p'}';
                }
                return Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.xs),
                  child: Text(text,
                      style:
                          AppText.caption.copyWith(color: AppColors.inkFaint)),
                );
              },
            ),
          ),
        ),
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (_) => AppColors.ink,
            getTooltipItems: (touched) => touched
                .map((s) => LineTooltipItem(
                      '${s.y.round()} bpm',
                      AppText.label.copyWith(
                          color: Colors.white, fontWeight: FontWeight.w700),
                    ))
                .toList(),
          ),
        ),
        // One bar per measured stretch, so periods with no readings are drawn
        // as breaks rather than bridged with an invented straight line.
        lineBarsData: [
          for (final segment in segments)
            LineChartBarData(
              spots: segment,
              isCurved: true,
              preventCurveOverShooting: true,
              color: AppColors.heart,
              barWidth: 3,
              dotData: FlDotData(
                // A lone reading has no line to draw, so show the point itself
                // — otherwise an isolated measurement vanishes from the chart.
                show: segment.length == 1,
                getDotPainter: (spot, _, __, ___) => FlDotCirclePainter(
                    radius: 3,
                    color: AppColors.heart,
                    strokeWidth: 0,
                    strokeColor: AppColors.heart),
              ),
              belowBarData: BarAreaData(
                show: true,
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    AppColors.heart.withValues(alpha: 0.18),
                    AppColors.heart.withValues(alpha: 0.0),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ===========================================================================
// Zone legend (labels the chart's HR-zone bands)
// ===========================================================================

class _ZoneLegend extends StatelessWidget {
  const _ZoneLegend();

  @override
  Widget build(BuildContext context) {
    Widget item(Color c, String label) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                  color: c.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(2)),
            ),
            const SizedBox(width: 5),
            Text(label,
                style: AppText.caption.copyWith(color: AppColors.inkMuted)),
          ],
        );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
      child: Wrap(
        spacing: AppSpacing.md,
        runSpacing: AppSpacing.xs,
        children: [
          item(AppColors.sleep, 'Resting <60'),
          item(AppColors.success, 'Normal 60–100'),
          item(AppColors.warning, 'Elevated 100+'),
        ],
      ),
    );
  }
}

// ===========================================================================
// Highest reading today + activity context (real correlation)
// ===========================================================================

// ===========================================================================
// Min / Avg / Max
// ===========================================================================

String _clock(DateTime t) {
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  return '$h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
}

class _SummaryLedger extends StatelessWidget {
  final List<HeartRateReading> readings;
  final bool week;

  /// Today's peak with its time and context; folded into the Highest row so
  /// the number is not shown twice.
  final HeartEvent? highest;
  const _SummaryLedger(
      {required this.readings, required this.week, this.highest});

  @override
  Widget build(BuildContext context) {
    String minStr = '—', avgStr = '—', maxStr = '—';
    if (readings.isNotEmpty) {
      final values = readings.map((r) => r.value).toList();
      final minV = values.reduce((a, b) => a < b ? a : b);
      final maxV = values.reduce((a, b) => a > b ? a : b);
      final avgV = (values.reduce((a, b) => a + b) / values.length).round();
      minStr = '$minV';
      avgStr = '$avgV';
      maxStr = '$maxV';
    }
    final unit = readings.isEmpty ? null : 'bpm';
    return LedgerGroup(
      rows: [
        LedgerRow(label: 'Lowest', value: minStr, unit: unit, color: AppColors.sleep),
        LedgerRow(label: 'Average', value: avgStr, unit: unit, color: AppColors.inkMuted),
        LedgerRow(
            label: 'Highest',
            value: maxStr,
            unit: unit,
            color: AppColors.heart,
            note: highest == null
                ? null
                : '${_clock(highest!.time)}'
                    '${highest!.duringActivity ? ' · during activity' : ' · at rest'}'),
      ],
      evidence: readings.isEmpty
          ? 'no readings in this range'
          : '${fmtThousands(readings.length)} readings '
              '${week ? 'in range' : 'today'} · one per minute from the band, '
              'plus live streaming',
    );
  }
}

class _WeekSummaryCard extends StatelessWidget {
  final HeartAnalysis heart;
  const _WeekSummaryCard({required this.heart});

  @override
  Widget build(BuildContext context) {
    if (!heart.hasPersonalBaseline) {
      return _HeartBaselineNote(
          count: heart.baselineDayCount, needed: heart.baselineDaysNeeded);
    }
    String v(int? x) => x != null ? '$x' : '—';
    return AppCard(
      child: Column(
        children: [
          Row(children: [
            Expanded(
                child: _CenterStat(label: 'Average', value: v(heart.weekAvg))),
            Container(width: 1, height: 34, color: AppColors.divider),
            Expanded(
                child: _CenterStat(
                    label: 'Resting',
                    value: v(heart.weekResting),
                    accent: AppColors.sleep)),
          ]),
          Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
            child: Divider(height: 1, color: AppColors.divider),
          ),
          Row(children: [
            Expanded(
                child: _CenterStat(label: 'Highest', value: v(heart.weekHigh))),
            Container(width: 1, height: 34, color: AppColors.divider),
            Expanded(
                child: _CenterStat(label: 'Lowest', value: v(heart.weekLow))),
          ]),
          if (heart.vsLastWeekAvg != null) ...[
            Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
              child: Divider(height: 1, color: AppColors.divider),
            ),
            _VsLastWeekRow(delta: heart.vsLastWeekAvg!),
          ],
        ],
      ),
    );
  }
}

/// Building-state note — personal weekly comparisons unlock only after enough
/// clean post-fix days (the shared [Baseline] gate). Mirrors the Sleep screen.
class _HeartBaselineNote extends StatelessWidget {
  final int count;
  final int needed;
  const _HeartBaselineNote({required this.count, required this.needed});

  @override
  Widget build(BuildContext context) {
    final frac = (count / needed).clamp(0.0, 1.0);
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.sleep.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: AppColors.sleep.withValues(alpha: 0.15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.insights_rounded, size: 15, color: AppColors.sleep),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text('Building your baseline · $count of $needed days',
                    style: AppText.caption.copyWith(
                        color: AppColors.ink, fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadii.pill),
            child: SizedBox(
              height: 5,
              child: Stack(children: [
                Container(color: AppColors.surfaceAlt),
                FractionallySizedBox(
                  widthFactor: frac,
                  child: Container(color: AppColors.sleep),
                ),
              ]),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Until then, your heart rate is compared to general healthy ranges. '
            'Weekly averages and "vs last week" unlock after $needed clean days.',
            style: AppText.caption.copyWith(color: AppColors.inkMuted),
          ),
        ],
      ),
    );
  }
}

class _CenterStat extends StatelessWidget {
  final String label;
  final String value;
  final Color? accent;
  // `accent` can no longer default to a palette colour: those are getters now
  // (dark mode), so the default is resolved at build time instead.
  const _CenterStat({required this.label, required this.value, this.accent});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(label, style: AppText.caption.copyWith(color: AppColors.inkMuted)),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(value,
                style:
                    AppText.title.copyWith(color: accent ?? AppColors.heart)),
            if (value != '—') ...[
              const SizedBox(width: 3),
              Text('bpm', style: AppText.unit),
            ],
          ],
        ),
      ],
    );
  }
}

/// Signed change in weekly average vs the previous 7 days. A lower average HR is
/// the favourable direction, so down = green, up = amber.
class _VsLastWeekRow extends StatelessWidget {
  final int delta; // weekAvg - prevWeekAvg
  const _VsLastWeekRow({required this.delta});

  @override
  Widget build(BuildContext context) {
    final improved = delta <= 0;
    final color = delta == 0
        ? AppColors.inkMuted
        : (improved ? AppColors.success : AppColors.warning);
    final icon = delta == 0
        ? Icons.trending_flat_rounded
        : (improved ? Icons.trending_down_rounded : Icons.trending_up_rounded);
    final text = delta == 0
        ? 'Same as last week'
        : '${delta.abs()} bpm ${improved ? 'lower' : 'higher'} than last week';
    return Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: AppSpacing.sm),
        Text('vs last week',
            style: AppText.label.copyWith(color: AppColors.ink)),
        const Spacer(),
        Flexible(
          child: Text(text,
              textAlign: TextAlign.end,
              style: AppText.caption.copyWith(color: color)),
        ),
      ],
    );
  }
}

// ===========================================================================
// Recommendations (generic-safe, non-medical)
// ===========================================================================

class _RecommendationsCard extends StatelessWidget {
  final List<String> items;
  const _RecommendationsCard({required this.items});

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) const SizedBox(height: AppSpacing.md),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  margin: const EdgeInsets.only(top: 5),
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                      color: AppColors.success, shape: BoxShape.circle),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text(items[i],
                      style: AppText.body.copyWith(color: AppColors.ink)),
                ),
              ],
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          Text('General wellness tips, not medical advice.',
              style: AppText.caption.copyWith(color: AppColors.inkFaint)),
        ],
      ),
    );
  }
}

// ===========================================================================
// More metrics — honest about what this band can and can't measure
// ===========================================================================

/// Stress and Recovery both need heart-rate variability (HRV), which the Mi
/// Band 6 doesn't expose over this protocol. Rather than fake them from BPM, we
/// surface them honestly: Stress is "coming soon", Recovery is omitted with the
/// reason. (Heart "score" is deliberately a trend/status view, not a number —
/// see docs/heart-score.md.)
class _MoreMetricsCard extends StatelessWidget {
  const _MoreMetricsCard();

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.symmetric(
          vertical: AppSpacing.sm, horizontal: AppSpacing.lg),
      child: Column(
        children: [
          // The old copy here said stress "needs HRV — coming soon". That
          // premise was wrong: Mi Band 6 measures stress on-device and reports
          // it over the legacy fetch channel (findings-20). What we genuinely
          // cannot do is HRV, because this firmware never sends RR intervals —
          // so Recovery below stays omitted with its real reason.
          _MetricRow(
            icon: Icons.bolt_rounded,
            color: AppColors.warning,
            title: 'Stress',
            // Driven by the same constant the Stress screen uses, so the two
            // can never disagree. It read "Measured by your band" throughout
            // the period the band's stream was quarantined for not decoding as
            // stress at all (findings-23).
            note: BLEManager.kStressFetchVerified
                ? 'Measured by your band'
                : 'Estimated from heart rate',
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const StressScreen(),
            )),
          ),
          Divider(height: 1, color: AppColors.divider),
          _MetricRow(
            icon: Icons.battery_charging_full_rounded,
            color: AppColors.inkFaint,
            title: 'Recovery',
            note: 'Needs HRV — not on Mi Band 6',
          ),
        ],
      ),
    );
  }
}

class _MetricRow extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String note;
  final VoidCallback? onTap;
  const _MetricRow({
    required this.icon,
    required this.color,
    required this.title,
    required this.note,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 19),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(child: Text(title, style: AppText.title)),
          Text(note,
              style: AppText.caption.copyWith(color: AppColors.inkMuted)),
          if (onTap != null) ...[
            const SizedBox(width: 4),
            Icon(Icons.chevron_right_rounded,
                color: AppColors.inkFaint, size: 20),
          ],
        ],
      ),
    );
    if (onTap == null) return row;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.sm),
        child: row,
      ),
    );
  }
}
