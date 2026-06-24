import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:provider/provider.dart';

import '../../core/ble_manager.dart';
import '../../core/activity_sample.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/app_card.dart';
import '../widgets/chart_card.dart';
import '../widgets/pulsing_heart_ring.dart';
import '../widgets/section_header.dart';
import '../widgets/segmented_toggle.dart';

/// The Heart screen: live BPM hero with realtime start/stop, a Today/Week
/// heart-rate trend chart, min/avg/max summary tiles and a resting HR card.
class HeartTab extends StatefulWidget {
  const HeartTab({super.key});

  @override
  State<HeartTab> createState() => _HeartTabState();
}

class _HeartTabState extends State<HeartTab> {
  int _range = 0; // 0 = Today, 1 = Week

  /// Heart-rate readings filtered to the selected range, sorted ascending.
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
    // Week: last 7 days (inclusive of today).
    final cutoff = DateTime(now.year, now.month, now.day)
        .subtract(const Duration(days: 6));
    return all.where((r) => !r.timestamp.isBefore(cutoff)).toList();
  }

  @override
  Widget build(BuildContext context) {
    final ble = context.watch<BLEManager>();
    final readings = _filtered(ble.activityStore.hrReadings);
    final isActive = ble.isRealtimeHeartRateActive;

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
                _HeroCard(
                  bpm: ble.heartRate,
                  measuring: isActive,
                  onToggle: () => isActive
                      ? ble.stopRealtimeHeartRate()
                      : ble.startRealtimeHeartRate(),
                ),
                const SizedBox(height: AppSpacing.lg),
                SectionHeader(
                  'Trend',
                  trailing: SegmentedToggle(
                    options: const ['Today', 'Week'],
                    index: _range,
                    accent: AppColors.heart,
                    onChanged: (i) => setState(() => _range = i),
                  ),
                ),
                ChartCard(
                  title: 'Heart rate',
                  subtitle: _range == 0 ? 'Today' : 'Last 7 days',
                  height: 220,
                  child: _HeartRateChart(readings: readings, week: _range == 1),
                ),
                const SizedBox(height: AppSpacing.lg),
                _SummaryRow(readings: readings),
                const SizedBox(height: AppSpacing.lg),
                _RestingCard(readings: readings),
              ],
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 96)),
      ],
    );
  }

  Widget _buildAppBar(BLEManager ble) {
    final bpm = ble.heartRate;
    return SliverAppBar(
      pinned: true,
      expandedHeight: 150,
      backgroundColor: AppColors.scaffold,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      automaticallyImplyLeading: false,
      flexibleSpace: FlexibleSpaceBar(
        background: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg, AppSpacing.xl, AppSpacing.lg, AppSpacing.lg),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Spacer(),
                Text('Heart', style: AppText.h1),
                const SizedBox(height: AppSpacing.xs),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Icon(Icons.favorite_rounded,
                        size: 14, color: AppColors.heart),
                    const SizedBox(width: AppSpacing.xs),
                    Text(
                      '${bpm ?? '--'} BPM now',
                      style: AppText.label,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Hero card: pulsing heart ring + a filled Start/Stop realtime pill button.
class _HeroCard extends StatelessWidget {
  final int? bpm;
  final bool measuring;
  final VoidCallback onToggle;

  const _HeroCard({
    required this.bpm,
    required this.measuring,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.symmetric(
          vertical: AppSpacing.xl, horizontal: AppSpacing.lg),
      child: Column(
        children: [
          PulsingHeartRing(bpm: bpm, size: 180, measuring: measuring),
          const SizedBox(height: AppSpacing.xl),
          _RealtimeButton(active: measuring, onTap: onToggle),
        ],
      ),
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
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.xl, vertical: AppSpacing.md),
          decoration: BoxDecoration(
            color: active ? AppColors.heartSoft : AppColors.heart,
            borderRadius: BorderRadius.circular(AppRadii.pill),
            boxShadow: active ? null : AppShadows.glow(AppColors.heart),
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
                active ? 'Stop' : 'Measure live',
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

/// The Today/Week heart-rate line chart.
class _HeartRateChart extends StatelessWidget {
  final List<HeartRateReading> readings;
  final bool week;
  const _HeartRateChart({required this.readings, required this.week});

  @override
  Widget build(BuildContext context) {
    if (readings.isEmpty) {
      return const ChartEmpty(
        message: 'No heart-rate history yet',
        icon: Icons.favorite_border_rounded,
      );
    }

    // X is the index (evenly spaced); timestamps are kept for axis + tooltips.
    final spots = <FlSpot>[
      for (var i = 0; i < readings.length; i++)
        FlSpot(i.toDouble(), readings[i].value.toDouble()),
    ];

    final values = readings.map((r) => r.value).toList();
    var minV = values.reduce((a, b) => a < b ? a : b).toDouble();
    var maxV = values.reduce((a, b) => a > b ? a : b).toDouble();
    // Pad the vertical range so the curve isn't glued to the edges.
    minV = (minV - 8).clamp(0, double.infinity);
    maxV = maxV + 8;
    if (maxV - minV < 20) maxV = minV + 20;
    final yInterval = ((maxV - minV) / 3).clamp(1, double.infinity).toDouble();

    final lastIndex = (readings.length - 1).toDouble();
    final labelStep = readings.length <= 1 ? 1.0 : lastIndex / 3;

    return LineChart(
      LineChartData(
        minX: 0,
        maxX: lastIndex == 0 ? 1 : lastIndex,
        minY: minV,
        maxY: maxV,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: yInterval,
          getDrawingHorizontalLine: (_) =>
              const FlLine(color: AppColors.divider, strokeWidth: 1),
        ),
        borderData: FlBorderData(show: false),
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
              getTitlesWidget: (value, meta) => Text(
                value.round().toString(),
                style: AppText.caption.copyWith(color: AppColors.inkFaint),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 22,
              interval: labelStep <= 0 ? 1 : labelStep,
              getTitlesWidget: (value, meta) {
                final i = value.round();
                if (i < 0 || i >= readings.length) {
                  return const SizedBox.shrink();
                }
                final t = readings[i].timestamp;
                final text = week
                    ? '${t.day}/${t.month}'
                    : '${t.hour.toString().padLeft(2, '0')}:'
                        '${t.minute.toString().padLeft(2, '0')}';
                return Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.xs),
                  child: Text(
                    text,
                    style:
                        AppText.caption.copyWith(color: AppColors.inkFaint),
                  ),
                );
              },
            ),
          ),
        ),
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (_) => AppColors.ink,
            getTooltipItems: (touched) => touched
                .map(
                  (s) => LineTooltipItem(
                    '${s.y.round()} bpm',
                    AppText.label.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                )
                .toList(),
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            preventCurveOverShooting: true,
            color: AppColors.heart,
            barWidth: 3,
            dotData: const FlDotData(show: false),
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

/// Three mini tiles: Min / Avg / Max BPM from the filtered readings.
class _SummaryRow extends StatelessWidget {
  final List<HeartRateReading> readings;
  const _SummaryRow({required this.readings});

  @override
  Widget build(BuildContext context) {
    String minStr = '--', avgStr = '--', maxStr = '--';
    if (readings.isNotEmpty) {
      final values = readings.map((r) => r.value).toList();
      final minV = values.reduce((a, b) => a < b ? a : b);
      final maxV = values.reduce((a, b) => a > b ? a : b);
      final avgV = (values.reduce((a, b) => a + b) / values.length).round();
      minStr = '$minV';
      avgStr = '$avgV';
      maxStr = '$maxV';
    }

    return Row(
      children: [
        Expanded(child: _MiniStat(label: 'Min', value: minStr)),
        const SizedBox(width: AppSpacing.md),
        Expanded(child: _MiniStat(label: 'Avg', value: avgStr)),
        const SizedBox(width: AppSpacing.md),
        Expanded(child: _MiniStat(label: 'Max', value: maxStr)),
      ],
    );
  }
}

class _MiniStat extends StatelessWidget {
  final String label;
  final String value;
  const _MiniStat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.symmetric(
          vertical: AppSpacing.lg, horizontal: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: Text(
                  value,
                  style: AppText.metricSm.copyWith(color: AppColors.heart),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (value != '--') ...[
                const SizedBox(width: 3),
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text('bpm', style: AppText.unit),
                ),
              ],
            ],
          ),
          const SizedBox(height: 2),
          Text(label, style: AppText.label),
        ],
      ),
    );
  }
}

/// Resting heart rate card — computed as the average of the lowest 10% of
/// readings (a friendlier estimate than a raw single minimum).
class _RestingCard extends StatelessWidget {
  final List<HeartRateReading> readings;
  const _RestingCard({required this.readings});

  @override
  Widget build(BuildContext context) {
    String resting = '--';
    if (readings.isNotEmpty) {
      final values = readings.map((r) => r.value).toList()..sort();
      final take = (values.length * 0.1).ceil().clamp(1, values.length);
      final lowest = values.take(take);
      final avgLow = (lowest.reduce((a, b) => a + b) / lowest.length).round();
      resting = '$avgLow';
    }

    return AppCard(
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppColors.heart.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(AppRadii.sm),
            ),
            child: Icon(Icons.bedtime_rounded,
                color: AppColors.heart, size: 22),
          ),
          const SizedBox(width: AppSpacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Resting heart rate', style: AppText.title),
                const SizedBox(height: 2),
                Text(
                  readings.isEmpty
                      ? 'Wear your band to track resting HR'
                      : 'Your calmest beats over this range',
                  style: AppText.caption.copyWith(color: AppColors.inkMuted),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                resting,
                style: AppText.metric.copyWith(color: AppColors.heart),
              ),
              if (resting != '--') ...[
                const SizedBox(width: 3),
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text('bpm', style: AppText.unit),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
