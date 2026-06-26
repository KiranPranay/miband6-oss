import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/ble_manager.dart';
import '../../core/activity_sample.dart';
import '../../core/sleep_analysis.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/app_card.dart';
import '../widgets/count_up_text.dart';
import '../widgets/section_header.dart';

/// The Sleep screen — coaches rather than just reports: a sleep score with
/// goal + night-over-night comparison, insights, a readable hypnogram timeline,
/// stage analysis with healthy ranges, key metrics, recommendations, a weekly
/// summary, and a day-wise session log (so naps are easy to spot).
class SleepTab extends StatefulWidget {
  const SleepTab({super.key});

  @override
  State<SleepTab> createState() => _SleepTabState();
}

class _SleepTabState extends State<SleepTab> {
  DateTime? _selectedStart;

  // ---- formatting ----------------------------------------------------------

  static String fmtMinutes(int m) {
    if (m < 60) return '${m}m';
    final h = m ~/ 60;
    final mm = m % 60;
    return mm == 0 ? '${h}h' : '${h}h ${mm}m';
  }

  static String clock(DateTime t) {
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m ${t.hour < 12 ? 'AM' : 'PM'}';
  }

  static const _weekdayShort = [
    'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun',
  ];
  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  /// Sleep that ended this morning is "Last night" — never "Today".
  String _nightLabel(DateTime wakeDate) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final d = DateTime(wakeDate.year, wakeDate.month, wakeDate.day);
    final diff = today.difference(d).inDays;
    if (diff <= 0) return 'Last night';
    if (diff == 1) return '2 nights ago';
    if (diff < 7) return '${diff + 1} nights ago';
    return '${_months[wakeDate.month - 1]} ${wakeDate.day}';
  }

  String _dayHeading(DateTime date) {
    final wd = _weekdayShort[(date.weekday - 1).clamp(0, 6)];
    return '$wd, ${date.day} ${_months[date.month - 1]}';
  }

  static Color ratingColor(int score) {
    if (score >= 85) return AppColors.success;
    if (score >= 70) return AppColors.sleep;
    if (score >= 55) return AppColors.warning;
    return AppColors.danger;
  }

  // ---- session selection ---------------------------------------------------

  List<SleepDay> _recent(List<SleepDay> days) {
    final ends = days.map((d) => d.endTime).whereType<DateTime>().toList();
    if (ends.isEmpty) return days;
    final latest = ends.reduce((a, b) => a.isAfter(b) ? a : b);
    final cutoff = latest.subtract(const Duration(hours: 40));
    return days.where((d) {
      final e = d.endTime;
      return e != null && !e.isBefore(cutoff);
    }).toList();
  }

  SleepDay? _main(List<SleepDay> recent) {
    final nights = recent.where((d) => !d.isNap).toList();
    final pool = nights.isNotEmpty ? nights : recent;
    if (pool.isEmpty) return null;
    return pool
        .reduce((a, b) => a.totalSleepMinutes >= b.totalSleepMinutes ? a : b);
  }

  List<SleepDay> _perNight(List<SleepDay> days) {
    final byDate = <String, SleepDay>{};
    for (final d in days.where((d) => !d.isNap)) {
      final key = '${d.date.year}-${d.date.month}-${d.date.day}';
      final cur = byDate[key];
      if (cur == null || d.totalSleepMinutes > cur.totalSleepMinutes) {
        byDate[key] = d;
      }
    }
    return byDate.values.toList()..sort((a, b) => a.date.compareTo(b.date));
  }

  // ---- build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final ble = context.watch<BLEManager>();
    final store = ble.activityStore;
    final days = store.computeSleepDays();
    final recent = _recent(days);

    SleepDay? selected;
    if (_selectedStart != null) {
      for (final d in recent) {
        if (d.startTime == _selectedStart) {
          selected = d;
          break;
        }
      }
    }
    selected ??= _main(recent) ?? (days.isNotEmpty ? days.last : null);

    final analysis = selected == null
        ? null
        : SleepAnalysis.compute(
            session: selected,
            allDays: days,
            hr: store.hrReadings,
            spo2: store.spo2Readings,
          );

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xs),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Sleep', style: AppText.h1),
                  const SizedBox(height: 2),
                  Text(
                    selected != null
                        ? (selected.isNap
                            ? 'Nap'
                            : _nightLabel(selected.date))
                        : 'Sleep tracking',
                    style: AppText.label.copyWith(color: AppColors.inkMuted),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (selected == null || analysis == null)
          _emptyState()
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                const SizedBox(height: AppSpacing.sm),
                _ScoreHero(a: analysis),
                const SizedBox(height: AppSpacing.lg),
                _InsightsCard(insights: analysis.insights),
                const SizedBox(height: AppSpacing.lg),
                _TimelineCard(day: selected),
                const SizedBox(height: AppSpacing.xl),
                const SectionHeader('Sleep stages'),
                _StageList(a: analysis),
                const SizedBox(height: AppSpacing.xl),
                const SectionHeader('Metrics'),
                _MetricsGrid(a: analysis),
                const SizedBox(height: AppSpacing.lg),
                _RecommendationsCard(recs: analysis.recommendations),
                const SizedBox(height: AppSpacing.xl),
                const SectionHeader('This week'),
                _WeeklySummary(a: analysis, nights: _perNight(days)),
                const SizedBox(height: AppSpacing.sm),
                _WeekChart(nights: _perNight(days)),
                if (recent.length > 1) ...[
                  const SizedBox(height: AppSpacing.xl),
                  const SectionHeader('Sleep log'),
                  _SessionsByDay(
                    sessions: recent,
                    selectedStart: selected.startTime,
                    headingFor: _dayHeading,
                    onSelect: (d) =>
                        setState(() => _selectedStart = d.startTime),
                  ),
                ],
              ]),
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 96)),
      ],
    );
  }

  Widget _emptyState() {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      sliver: SliverList(
        delegate: SliverChildListDelegate([
          const SizedBox(height: AppSpacing.sm),
          AppCard(
            padding: const EdgeInsets.all(AppSpacing.xxl),
            child: Column(
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: AppColors.sleep.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.nightlight_round,
                      color: AppColors.sleep, size: 30),
                ),
                const SizedBox(height: AppSpacing.lg),
                Text('No sleep data yet',
                    style: AppText.title, textAlign: TextAlign.center),
                const SizedBox(height: AppSpacing.sm),
                Text('Wear your band to bed to see your sleep analysis here.',
                    style: AppText.body.copyWith(color: AppColors.inkMuted),
                    textAlign: TextAlign.center),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

// ===========================================================================
// Score hero
// ===========================================================================

class _ScoreHero extends StatelessWidget {
  final SleepAnalysis a;
  const _ScoreHero({required this.a});

  @override
  Widget build(BuildContext context) {
    final color = _SleepTabState.ratingColor(a.score);
    final goalPct = a.goalPct.clamp(0, 100);

    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _ScoreRing(score: a.score, color: color),
              const SizedBox(width: AppSpacing.xl),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Sleep score',
                        style: AppText.label.copyWith(
                            color: AppColors.inkMuted,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(a.rating,
                        style: AppText.h1.copyWith(color: color)),
                    const SizedBox(height: AppSpacing.sm),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(_SleepTabState.fmtMinutes(a.durationMin),
                            style: AppText.metric),
                        const SizedBox(width: 6),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 3),
                          child: Text('asleep', style: AppText.label),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          _GoalBar(
            value: a.durationMin,
            goal: a.goalMin,
            pct: goalPct,
            color: color,
          ),
          if (a.vsYesterdayMin != null) ...[
            const SizedBox(height: AppSpacing.md),
            _DeltaLine(deltaMin: a.vsYesterdayMin!),
          ],
        ],
      ),
    );
  }
}

class _ScoreRing extends StatelessWidget {
  final int score;
  final Color color;
  const _ScoreRing({required this.score, required this.color});

  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.reduced(context);
    return SizedBox(
      width: 96,
      height: 96,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: score / 100),
        duration: reduced ? Duration.zero : AppMotion.slow,
        curve: AppMotion.ease,
        builder: (context, v, _) {
          return CustomPaint(
            painter: _RingPainter(progress: v, color: color),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CountUpText(score,
                      style: AppText.metric.copyWith(color: AppColors.ink)),
                  Text('/ 100',
                      style: AppText.caption
                          .copyWith(color: AppColors.inkFaint)),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double progress;
  final Color color;
  _RingPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2 - 6;
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: 0.14);
    canvas.drawCircle(c, r, track);
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9
      ..strokeCap = StrokeCap.round
      ..color = color;
    canvas.drawArc(Rect.fromCircle(center: c, radius: r), -1.5708,
        6.2832 * progress.clamp(0, 1), false, arc);
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      old.progress != progress || old.color != color;
}

class _GoalBar extends StatelessWidget {
  final int value;
  final int goal;
  final int pct;
  final Color color;
  const _GoalBar({
    required this.value,
    required this.goal,
    required this.pct,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.reduced(context);
    final frac = (value / goal).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Goal ${_SleepTabState.fmtMinutes(goal)}',
                style: AppText.label.copyWith(color: AppColors.inkMuted)),
            const Spacer(),
            Text('$pct%',
                style: AppText.label
                    .copyWith(color: color, fontWeight: FontWeight.w800)),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadii.pill),
          child: SizedBox(
            height: 10,
            child: Stack(
              children: [
                Container(color: AppColors.surfaceAlt),
                LayoutBuilder(
                  builder: (context, c) {
                    final w = c.maxWidth * frac;
                    final bar = Container(
                      width: w,
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(AppRadii.pill),
                      ),
                    );
                    if (reduced) return bar;
                    return TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0, end: w),
                      duration: AppMotion.slow,
                      curve: AppMotion.ease,
                      builder: (context, ww, _) => Container(
                        width: ww,
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(AppRadii.pill),
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _DeltaLine extends StatelessWidget {
  final int deltaMin;
  const _DeltaLine({required this.deltaMin});

  @override
  Widget build(BuildContext context) {
    final up = deltaMin >= 0;
    final color = up ? AppColors.success : AppColors.warning;
    final mag = _SleepTabState.fmtMinutes(deltaMin.abs());
    return Row(
      children: [
        Icon(up ? Icons.trending_up_rounded : Icons.trending_down_rounded,
            size: 16, color: color),
        const SizedBox(width: 6),
        Text(
          deltaMin == 0
              ? 'Same as the night before'
              : '$mag ${up ? 'more' : 'less'} than the night before',
          style: AppText.label.copyWith(color: AppColors.ink),
        ),
      ],
    );
  }
}

// ===========================================================================
// Insights
// ===========================================================================

class _InsightsCard extends StatelessWidget {
  final List<SleepInsight> insights;
  const _InsightsCard({required this.insights});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.lightbulb_rounded,
                  size: 18, color: AppColors.primary),
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
                  color: insights[i].good
                      ? AppColors.success
                      : AppColors.warning,
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
// Timeline (hypnogram) — taller, thicker, legend + clear axis
// ===========================================================================

class _TimelineCard extends StatelessWidget {
  final SleepDay day;
  const _TimelineCard({required this.day});

  @override
  Widget build(BuildContext context) {
    final start = day.startTime;
    final end = day.endTime;
    final hasData = day.intervals.isNotEmpty && start != null && end != null;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Sleep timeline', style: AppText.title),
              const Spacer(),
              if (hasData)
                Text('${_SleepTabState.clock(start)} – ${_SleepTabState.clock(end)}',
                    style: AppText.caption.copyWith(color: AppColors.inkMuted)),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          if (!hasData)
            SizedBox(
              height: 80,
              child: Center(
                child: Text('No stage data',
                    style: AppText.label.copyWith(color: AppColors.inkFaint)),
              ),
            )
          else ...[
            SizedBox(
              height: 220,
              child: CustomPaint(
                painter: _HypnoPainter(
                    intervals: day.intervals, start: start, end: end),
                child: const SizedBox.expand(),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            const _StageLegend(),
          ],
        ],
      ),
    );
  }
}

class _StageLegend extends StatelessWidget {
  const _StageLegend();

  @override
  Widget build(BuildContext context) {
    Widget dot(Color c, String l) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 11,
              height: 11,
              decoration:
                  BoxDecoration(color: c, borderRadius: BorderRadius.circular(3)),
            ),
            const SizedBox(width: 6),
            Text(l, style: AppText.caption.copyWith(color: AppColors.inkMuted)),
          ],
        );
    return Wrap(
      spacing: AppSpacing.lg,
      runSpacing: AppSpacing.sm,
      children: [
        dot(AppColors.sleepAwake, 'Awake'),
        dot(AppColors.sleepRem, 'REM'),
        dot(AppColors.sleepLight, 'Light'),
        dot(AppColors.sleepDeep, 'Deep'),
      ],
    );
  }
}

class _HypnoPainter extends CustomPainter {
  final List<SleepInterval> intervals;
  final DateTime start;
  final DateTime end;
  _HypnoPainter({required this.intervals, required this.start, required this.end});

  int _level(SleepStage s) {
    switch (s) {
      case SleepStage.awake:
        return 0;
      case SleepStage.rem:
        return 1;
      case SleepStage.light:
      case SleepStage.nap:
        return 2;
      case SleepStage.deep:
        return 3;
    }
  }

  static const _rowLabels = ['Awake', 'REM', 'Light', 'Deep'];
  static const _rowColors = [
    AppColors.sleepAwake,
    AppColors.sleepRem,
    AppColors.sleepLight,
    AppColors.sleepDeep,
  ];

  @override
  void paint(Canvas canvas, Size size) {
    const padL = 46.0, padB = 20.0, padT = 6.0, padR = 8.0;
    final plot =
        Rect.fromLTRB(padL, padT, size.width - padR, size.height - padB);
    final spanMs = end.difference(start).inMilliseconds;
    if (spanMs <= 0 || plot.width <= 0) return;

    const rows = 4;
    final rowH = plot.height / rows;
    double rowCenter(int lvl) => plot.top + rowH * lvl + rowH / 2;
    double xAt(DateTime t) =>
        plot.left + (t.difference(start).inMilliseconds / spanMs) * plot.width;

    final grid = Paint()
      ..color = AppColors.divider
      ..strokeWidth = 1;
    for (var i = 0; i < rows; i++) {
      final cy = rowCenter(i);
      canvas.drawLine(Offset(plot.left, cy), Offset(plot.right, cy), grid);
      _text(canvas, _rowLabels[i], Offset(0, cy - 7),
          color: _rowColors[i], size: 11, weight: FontWeight.w700);
    }

    final stepHours = spanMs > 6 * 3600 * 1000 ? 2 : 1;
    final hourPaint = Paint()
      ..color = AppColors.divider.withValues(alpha: 0.6)
      ..strokeWidth = 1;
    var tick = DateTime(start.year, start.month, start.day, start.hour)
        .add(const Duration(hours: 1));
    while (tick.isBefore(end)) {
      final x = xAt(tick);
      canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), hourPaint);
      _text(canvas, _hourLabel(tick), Offset(x - 13, plot.bottom + 5),
          color: AppColors.inkFaint, size: 10);
      tick = tick.add(Duration(hours: stepHours));
    }
    _text(canvas, _hourLabel(start), Offset(plot.left - 6, plot.bottom + 5),
        color: AppColors.inkMuted, size: 10, weight: FontWeight.w700);
    _text(canvas, _hourLabel(end), Offset(plot.right - 32, plot.bottom + 5),
        color: AppColors.inkMuted, size: 10, weight: FontWeight.w700);

    final segH = rowH * 0.6;
    int? prevLvl;
    for (final iv in intervals) {
      final lvl = _level(iv.stage);
      final x0 = xAt(iv.startTime);
      var x1 = xAt(iv.endTime);
      if (x1 < x0 + 3) x1 = x0 + 3;
      final cy = rowCenter(lvl);
      if (prevLvl != null) {
        canvas.drawLine(
          Offset(x0, rowCenter(prevLvl)),
          Offset(x0, cy),
          Paint()
            ..color = AppColors.sleepLight.withValues(alpha: 0.5)
            ..strokeWidth = 2.5,
        );
      }
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTRB(x0, cy - segH / 2, x1, cy + segH / 2),
        const Radius.circular(4),
      );
      canvas.drawRRect(rect, Paint()..color = _color(iv.stage));
      prevLvl = lvl;
    }
  }

  Color _color(SleepStage s) {
    switch (s) {
      case SleepStage.deep:
        return AppColors.sleepDeep;
      case SleepStage.light:
      case SleepStage.nap:
        return AppColors.sleepLight;
      case SleepStage.rem:
        return AppColors.sleepRem;
      case SleepStage.awake:
        return AppColors.sleepAwake;
    }
  }

  String _hourLabel(DateTime t) {
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    return '$h${t.hour < 12 ? 'a' : 'p'}';
  }

  void _text(Canvas canvas, String s, Offset at,
      {required Color color,
      required double size,
      FontWeight weight = FontWeight.w600}) {
    final tp = TextPainter(
      text: TextSpan(
          text: s,
          style: TextStyle(color: color, fontSize: size, fontWeight: weight)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(covariant _HypnoPainter old) =>
      old.intervals != intervals || old.start != start || old.end != end;
}

// ===========================================================================
// Stage list — minutes, % , healthy range, progress, vs-average
// ===========================================================================

class _StageList extends StatelessWidget {
  final SleepAnalysis a;
  const _StageList({required this.a});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < a.stages.length; i++) ...[
          if (i > 0) const SizedBox(height: AppSpacing.md),
          _StageRow(stat: a.stages[i], totalMin: a.durationMin),
        ],
      ],
    );
  }
}

class _StageRow extends StatelessWidget {
  final StageStat stat;
  final int totalMin;
  const _StageRow({required this.stat, required this.totalMin});

  Color get _color {
    switch (stat.stage) {
      case SleepStage.deep:
        return AppColors.sleepDeep;
      case SleepStage.rem:
        return AppColors.sleepRem;
      default:
        return AppColors.sleepLight;
    }
  }

  ({String text, Color color}) get _status {
    switch (stat.status) {
      case MetricStatus.below:
        return (text: 'Below average', color: AppColors.warning);
      case MetricStatus.above:
        return (text: 'Above average', color: AppColors.primary);
      case MetricStatus.normal:
        return (text: 'Normal', color: AppColors.success);
    }
  }

  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.reduced(context);
    final s = _status;
    final frac = stat.targetMinutes > 0
        ? (stat.minutes / stat.targetMinutes).clamp(0.0, 1.0)
        : 0.0;
    final lowMin = (totalMin * stat.normalLowPct / 100).round();
    final highMin = (totalMin * stat.normalHighPct / 100).round();

    return AppCard(
      color: Color.alphaBlend(_color.withValues(alpha: 0.045), AppColors.surface),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                    color: _color, borderRadius: BorderRadius.circular(4)),
              ),
              const SizedBox(width: AppSpacing.sm),
              Text('${stat.label} sleep', style: AppText.title),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: s.color.withValues(alpha: 0.13),
                  borderRadius: BorderRadius.circular(AppRadii.pill),
                ),
                child: Text(s.text,
                    style: AppText.caption
                        .copyWith(color: s.color, fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(_SleepTabState.fmtMinutes(stat.minutes),
                  style: AppText.metricSm),
              const SizedBox(width: 6),
              Text('${stat.pct}%',
                  style: AppText.label.copyWith(color: AppColors.inkMuted)),
              const Spacer(),
              Text(
                stat.deltaVsAvg == 0
                    ? 'on average'
                    : '${stat.deltaVsAvg > 0 ? '+' : '−'}${_SleepTabState.fmtMinutes(stat.deltaVsAvg.abs())} vs avg',
                style: AppText.caption.copyWith(color: AppColors.inkMuted),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadii.pill),
            child: SizedBox(
              height: 8,
              child: Stack(
                children: [
                  Container(color: AppColors.surfaceAlt),
                  LayoutBuilder(builder: (context, c) {
                    final w = c.maxWidth * frac;
                    if (reduced) {
                      return Container(
                          width: w,
                          decoration: BoxDecoration(
                              color: _color,
                              borderRadius:
                                  BorderRadius.circular(AppRadii.pill)));
                    }
                    return TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0, end: w),
                      duration: AppMotion.slow,
                      curve: AppMotion.ease,
                      builder: (context, ww, _) => Container(
                          width: ww,
                          decoration: BoxDecoration(
                              color: _color,
                              borderRadius:
                                  BorderRadius.circular(AppRadii.pill))),
                    );
                  }),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text('Healthy: ${_SleepTabState.fmtMinutes(lowMin)}–${_SleepTabState.fmtMinutes(highMin)}',
              style: AppText.caption.copyWith(color: AppColors.inkFaint)),
        ],
      ),
    );
  }
}

// ===========================================================================
// Metrics grid (only what the band actually measures)
// ===========================================================================

class _MetricsGrid extends StatelessWidget {
  final SleepAnalysis a;
  const _MetricsGrid({required this.a});

  @override
  Widget build(BuildContext context) {
    final cells = <Widget>[
      _MetricTile(
        icon: Icons.speed_rounded,
        color: AppColors.activity,
        label: 'Efficiency',
        value: '${a.efficiencyPct}%',
        sub: a.efficiencyPct >= 90 ? 'Excellent' : 'Fair',
      ),
      _MetricTile(
        icon: Icons.favorite_rounded,
        color: AppColors.heart,
        label: 'Avg heart rate',
        value: a.avgHr != null ? '${a.avgHr}' : '—',
        sub: a.avgHr != null ? 'bpm' : 'no data',
      ),
      _MetricTile(
        icon: Icons.water_drop_rounded,
        color: AppColors.spo2,
        label: 'Blood oxygen',
        value: a.avgSpo2 != null ? '${a.avgSpo2}%' : '—',
        sub: a.avgSpo2 != null ? 'avg SpO₂' : 'no data',
      ),
      _MetricTile(
        icon: Icons.hotel_rounded,
        color: AppColors.sleep,
        label: 'Time in bed',
        value: _SleepTabState.fmtMinutes(a.timeInBedMin),
        sub: 'total',
      ),
      _MetricTile(
        icon: Icons.bedtime_off_rounded,
        color: AppColors.warning,
        label: 'Wake-ups',
        value: '${a.wakeCount}',
        sub: a.wakeCount == 0 ? 'undisturbed' : 'times',
      ),
      _MetricTile(
        icon: Icons.monitor_heart_rounded,
        color: AppColors.heart,
        label: 'Resting HR',
        value: a.restingHr != null ? '${a.restingHr}' : '—',
        sub: a.restingHr != null ? 'bpm' : 'no data',
      ),
    ];
    return Column(
      children: [
        Row(children: [
          Expanded(child: cells[0]),
          const SizedBox(width: AppSpacing.md),
          Expanded(child: cells[1]),
        ]),
        const SizedBox(height: AppSpacing.md),
        Row(children: [
          Expanded(child: cells[2]),
          const SizedBox(width: AppSpacing.md),
          Expanded(child: cells[3]),
        ]),
        const SizedBox(height: AppSpacing.md),
        Row(children: [
          Expanded(child: cells[4]),
          const SizedBox(width: AppSpacing.md),
          Expanded(child: cells[5]),
        ]),
      ],
    );
  }
}

class _MetricTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final String value;
  final String sub;
  const _MetricTile({
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
    required this.sub,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: color, size: 18),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(label,
                    style: AppText.caption.copyWith(color: AppColors.inkMuted)),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(value, style: AppText.metricSm),
              const SizedBox(width: 4),
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(sub,
                    style: AppText.caption.copyWith(color: AppColors.inkFaint)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ===========================================================================
// Recommendations
// ===========================================================================

class _RecommendationsCard extends StatelessWidget {
  final List<String> recs;
  const _RecommendationsCard({required this.recs});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppColors.primary.withValues(alpha: 0.10),
            AppColors.sleep.withValues(alpha: 0.10),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(AppRadii.lg),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.auto_awesome_rounded,
                  size: 18, color: AppColors.primary),
              const SizedBox(width: AppSpacing.sm),
              Text('Recommendations', style: AppText.title),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          for (var i = 0; i < recs.length; i++) ...[
            if (i > 0) const SizedBox(height: AppSpacing.sm),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                        color: AppColors.primary, shape: BoxShape.circle),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                    child: Text(recs[i],
                        style: AppText.body.copyWith(color: AppColors.ink))),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// ===========================================================================
// Weekly summary + chart
// ===========================================================================

class _WeeklySummary extends StatelessWidget {
  final SleepAnalysis a;
  final List<SleepDay> nights;
  const _WeeklySummary({required this.a, required this.nights});

  String _weekdayLong(DateTime d) {
    const names = [
      'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday',
    ];
    return names[(d.weekday - 1).clamp(0, 6)];
  }

  @override
  Widget build(BuildContext context) {
    final stat = <Widget>[
      _MiniStat(
        label: 'Average',
        value: a.weekAvgMin != null
            ? _SleepTabState.fmtMinutes(a.weekAvgMin!)
            : '—',
      ),
      _MiniStat(
        label: 'Consistency',
        value: a.consistencyPct != null ? '${a.consistencyPct}%' : '—',
      ),
      _MiniStat(
        label: 'Best night',
        value: a.bestNight != null ? _weekdayLong(a.bestNight!.date) : '—',
      ),
      _MiniStat(
        label: 'Lowest night',
        value: a.worstNight != null ? _weekdayLong(a.worstNight!.date) : '—',
      ),
    ];
    return AppCard(
      child: Column(
        children: [
          Row(children: [
            Expanded(child: stat[0]),
            Container(width: 1, height: 34, color: AppColors.divider),
            Expanded(child: stat[1]),
          ]),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
            child: Divider(height: 1, color: AppColors.divider),
          ),
          Row(children: [
            Expanded(child: stat[2]),
            Container(width: 1, height: 34, color: AppColors.divider),
            Expanded(child: stat[3]),
          ]),
        ],
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  final String label;
  final String value;
  const _MiniStat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(label,
            style: AppText.caption.copyWith(color: AppColors.inkMuted)),
        const SizedBox(height: 4),
        Text(value, style: AppText.title),
      ],
    );
  }
}

class _WeekChart extends StatelessWidget {
  final List<SleepDay> nights;
  const _WeekChart({required this.nights});

  @override
  Widget build(BuildContext context) {
    final recent =
        nights.length <= 7 ? nights : nights.sublist(nights.length - 7);
    if (recent.length < 2) {
      return AppCard(
        child: SizedBox(
          height: 120,
          child: Center(
            child: Text('Not enough nights yet',
                style: AppText.label.copyWith(color: AppColors.inkFaint)),
          ),
        ),
      );
    }
    final maxMinutes = recent
        .map((d) => d.totalSleepMinutes)
        .fold<int>(0, (a, b) => a > b ? a : b);
    final maxY = (maxMinutes <= 0 ? 60 : maxMinutes) * 1.2;
    const labels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

    return AppCard(
      child: SizedBox(
        height: 168,
        child: BarChart(
          BarChartData(
            alignment: BarChartAlignment.spaceAround,
            maxY: maxY,
            minY: 0,
            gridData: FlGridData(
              show: true,
              drawVerticalLine: false,
              getDrawingHorizontalLine: (v) =>
                  FlLine(color: AppColors.divider, strokeWidth: 1),
            ),
            borderData: FlBorderData(show: false),
            titlesData: FlTitlesData(
              topTitles:
                  const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              rightTitles:
                  const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              leftTitles:
                  const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 22,
                  getTitlesWidget: (value, meta) {
                    final i = value.toInt();
                    if (i < 0 || i >= recent.length) {
                      return const SizedBox.shrink();
                    }
                    final wd = recent[i].date.weekday;
                    return Padding(
                      padding: const EdgeInsets.only(top: AppSpacing.sm),
                      child: Text(labels[(wd - 1).clamp(0, 6)],
                          style: AppText.caption.copyWith(
                              color: AppColors.inkMuted, fontSize: 10)),
                    );
                  },
                ),
              ),
            ),
            barTouchData: BarTouchData(
              touchTooltipData: BarTouchTooltipData(
                getTooltipColor: (g) => AppColors.ink,
                tooltipRoundedRadius: AppRadii.sm,
                getTooltipItem: (g, gi, rod, ri) => BarTooltipItem(
                  _SleepTabState.fmtMinutes(rod.toY.round()),
                  AppText.caption.copyWith(color: Colors.white),
                ),
              ),
            ),
            barGroups: [
              for (var i = 0; i < recent.length; i++)
                BarChartGroupData(x: i, barRods: [
                  BarChartRodData(
                    toY: recent[i].totalSleepMinutes.toDouble(),
                    color: AppColors.sleep,
                    width: 16,
                    borderRadius:
                        const BorderRadius.vertical(top: Radius.circular(6)),
                  ),
                ]),
            ],
          ),
        ),
      ),
    );
  }
}

// ===========================================================================
// Day-wise session log
// ===========================================================================

class _SessionsByDay extends StatelessWidget {
  final List<SleepDay> sessions;
  final DateTime? selectedStart;
  final String Function(DateTime) headingFor;
  final ValueChanged<SleepDay> onSelect;
  const _SessionsByDay({
    required this.sessions,
    required this.selectedStart,
    required this.headingFor,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    // Group by wake date, newest first.
    final groups = <DateTime, List<SleepDay>>{};
    for (final s in sessions) {
      final e = s.endTime ?? s.date;
      final key = DateTime(e.year, e.month, e.day);
      groups.putIfAbsent(key, () => []).add(s);
    }
    final keys = groups.keys.toList()..sort((a, b) => b.compareTo(a));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final k in keys) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.xs, AppSpacing.sm, 0, AppSpacing.sm),
            child: Text(headingFor(k),
                style: AppText.label
                    .copyWith(color: AppColors.inkMuted, fontWeight: FontWeight.w800)),
          ),
          for (final s in (groups[k]!
            ..sort((a, b) => (b.startTime ?? b.date)
                .compareTo(a.startTime ?? a.date)))) ...[
            _SessionRow(
              day: s,
              selected: s.startTime == selectedStart,
              onTap: () => onSelect(s),
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ],
      ],
    );
  }
}

class _SessionRow extends StatelessWidget {
  final SleepDay day;
  final bool selected;
  final VoidCallback onTap;
  const _SessionRow({
    required this.day,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final start = day.startTime;
    final end = day.endTime;
    final nap = day.isNap;
    final color = nap ? AppColors.calories : AppColors.sleep;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.lg),
        child: Container(
          padding: EdgeInsets.all(nap ? AppSpacing.md : AppSpacing.lg),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadii.lg),
            border: Border.all(
              color: selected ? AppColors.sleep : AppColors.divider,
              width: selected ? 1.6 : 1,
            ),
            boxShadow: AppShadows.card,
          ),
          child: Row(
            children: [
              Container(
                width: nap ? 36 : 42,
                height: nap ? 36 : 42,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  nap ? Icons.wb_twilight_rounded : Icons.bedtime_rounded,
                  color: color,
                  size: nap ? 18 : 22,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(nap ? 'Nap' : 'Night sleep',
                      style: nap ? AppText.label.copyWith(color: AppColors.ink, fontWeight: FontWeight.w700) : AppText.title),
                  const SizedBox(height: 2),
                  if (start != null && end != null)
                    Text(
                      '${_SleepTabState.clock(start)} – ${_SleepTabState.clock(end)}',
                      style: AppText.caption.copyWith(color: AppColors.inkMuted),
                    ),
                ],
              ),
              const Spacer(),
              Text(day.durationString,
                  style: nap
                      ? AppText.title
                      : AppText.metricSm.copyWith(fontSize: 19)),
            ],
          ),
        ),
      ),
    );
  }
}
