import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/activity_sample.dart';
import '../core/ble_manager.dart';
import '../core/stress_analyzer.dart';
import 'theme/app_theme.dart';
import 'theme/tokens.dart';
import 'widgets/app_card.dart';
import 'widgets/section_header.dart';

/// Stress — the band's own measurement, with an honest fallback.
///
/// Two rules this screen holds to:
///
/// * **Say where the number came from.** A band measurement and an app-side
///   estimate are visually distinct and always labelled. The user should never
///   have to guess whether a figure was measured or inferred.
/// * **No medical framing.** Ranges and trends only; the wording avoids
///   diagnosis, and the breathing suggestion is offered, not urged.
class StressScreen extends StatelessWidget {
  const StressScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final ble = context.read<BLEManager>();
    return ListenableBuilder(
      listenable: ble.activityStore.revisionListenable,
      builder: (context, _) => _StressBody(ble: ble),
    );
  }
}

class _StressBody extends StatelessWidget {
  const _StressBody({required this.ble});
  final BLEManager ble;

  @override
  Widget build(BuildContext context) {
    final store = ble.activityStore;
    final now = DateTime.now();
    final estimate = StressAnalyzer.current(
      bandReadings: store.stressReadings,
      hrReadings: store.hrReadings,
      now: now,
      rrIntervalsMs: ble.recentRrIntervalsMs,
    );
    final daily = StressAnalyzer.dailyAverages(store.stressReadings);
    final today = store.stressReadings
        .where((r) =>
            r.timestamp.year == now.year &&
            r.timestamp.month == now.month &&
            r.timestamp.day == now.day)
        .toList();

    return Scaffold(
      backgroundColor: AppColors.scaffold,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: AppColors.ink),
        title: const Text('Stress'),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg,
            AppSpacing.xxl + MediaQuery.viewPaddingOf(context).bottom),
        children: [
          _Hero(estimate: estimate),
          const SizedBox(height: AppSpacing.lg),
          if (StressAnalyzer.suggestBreathing(estimate)) ...[
            const _BreathingSuggestion(),
            const SizedBox(height: AppSpacing.lg),
          ],
          if (today.isNotEmpty) ...[
            const SectionHeader('Today'),
            _TodayCard(readings: today),
            const SizedBox(height: AppSpacing.lg),
          ],
          if (daily.length >= 2) ...[
            const SectionHeader('Last 7 days'),
            _TrendCard(daily: daily),
            const SizedBox(height: AppSpacing.lg),
          ],
          const SectionHeader('How this is measured'),
          _MethodCard(estimate: estimate),
        ],
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.estimate});
  final StressEstimate estimate;

  Color get _accent => switch (estimate.score) {
        null => AppColors.inkFaint,
        final s when s < 30 => AppColors.success,
        final s when s < 60 => AppColors.stress,
        final s when s < 80 => AppColors.warning,
        _ => AppColors.danger,
      };

  @override
  Widget build(BuildContext context) {
    final score = estimate.score;
    return AppCard(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  score?.toString() ?? '--',
                  style: AppText.h1.copyWith(
                    fontSize: 56,
                    height: 1,
                    color: _accent,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(estimate.label,
                      style: AppText.title.copyWith(color: _accent)),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            // The provenance chip is deliberately adjacent to the number.
            _SourceChip(source: estimate.source),
            const SizedBox(height: AppSpacing.sm),
            Text(estimate.explanation,
                style: AppText.caption.copyWith(color: AppColors.inkMuted)),
          ],
        ),
      ),
    );
  }
}

class _SourceChip extends StatelessWidget {
  const _SourceChip({required this.source});
  final StressSource source;

  @override
  Widget build(BuildContext context) {
    final measured = source == StressSource.band;
    final color = measured ? AppColors.success : AppColors.inkMuted;
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadii.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(measured ? Icons.watch_rounded : Icons.calculate_outlined,
              size: 13, color: color),
          const SizedBox(width: 6),
          Text(measured ? 'Measured by band' : 'Estimated by app',
              style: AppText.caption
                  .copyWith(color: color, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _BreathingSuggestion extends StatelessWidget {
  const _BreathingSuggestion();

  @override
  Widget build(BuildContext context) => AppCard(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Row(
            children: [
              const Icon(Icons.air_rounded, color: Color(0xFF0E9488)),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(
                  'Your reading is above your usual range. A few slow breaths '
                  'often helps — no pressure either way.',
                  style: AppText.body,
                ),
              ),
            ],
          ),
        ),
      );
}

class _TodayCard extends StatelessWidget {
  const _TodayCard({required this.readings});
  final List<StressReading> readings;

  @override
  Widget build(BuildContext context) {
    final values = readings.map((r) => r.value).toList();
    final avg = (values.reduce((a, b) => a + b) / values.length).round();
    final lo = values.reduce((a, b) => a < b ? a : b);
    final hi = values.reduce((a, b) => a > b ? a : b);
    return AppCard(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _Stat(label: 'Average', value: '$avg'),
            _Stat(label: 'Lowest', value: '$lo'),
            _Stat(label: 'Highest', value: '$hi'),
            _Stat(label: 'Readings', value: '${readings.length}'),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Text(value,
              style: AppText.title.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(label,
              style: AppText.caption.copyWith(color: AppColors.inkMuted)),
        ],
      );
}

class _TrendCard extends StatelessWidget {
  const _TrendCard({required this.daily});
  final List<({DateTime date, int average, int samples})> daily;

  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  @override
  Widget build(BuildContext context) {
    final maxV = daily.map((d) => d.average).reduce((a, b) => a > b ? a : b);
    return AppCard(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        // RepaintBoundary: the bars are static between data changes, so they
        // should not be re-rasterised when anything else on the page moves.
        child: RepaintBoundary(
          child: SizedBox(
            height: 140,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                for (final d in daily)
                  Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text('${d.average}',
                          style: AppText.caption
                              .copyWith(color: AppColors.inkMuted)),
                      const SizedBox(height: 4),
                      Container(
                        width: 20,
                        height: maxV == 0
                            ? 4
                            : (d.average / maxV * 92).clamp(4, 92).toDouble(),
                        decoration: BoxDecoration(
                          color: AppColors.stress,
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(_weekdays[(d.date.weekday - 1) % 7],
                          style: AppText.caption
                              .copyWith(color: AppColors.inkFaint)),
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

class _MethodCard extends StatelessWidget {
  const _MethodCard({required this.estimate});
  final StressEstimate estimate;

  @override
  Widget build(BuildContext context) => AppCard(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Your Mi Band 6 calculates a stress score itself and stores it '
                'through the day. We read those values — we do not re-invent '
                'them.',
                style: AppText.body,
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                'When the band has no recent reading, we fall back to how far '
                'your heart rate sits above your own resting range. That is an '
                'estimate, and it is labelled as one.',
                style: AppText.caption.copyWith(color: AppColors.inkMuted),
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                'True heart-rate variability (HRV) needs beat-to-beat timing, '
                'which this band does not report — so there is no HRV or '
                'recovery figure here rather than a guess dressed up as one.',
                style: AppText.caption.copyWith(color: AppColors.inkMuted),
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                'For information only — not a medical measurement.',
                style: AppText.caption.copyWith(color: AppColors.inkFaint),
              ),
            ],
          ),
        ),
      );
}
