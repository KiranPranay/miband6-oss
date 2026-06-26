import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/ble_manager.dart';
import '../../core/activity_sample.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/app_card.dart';
import '../widgets/chart_card.dart';
import '../widgets/section_header.dart';

/// The Sleep screen: a selectable session (last night or a nap), a time-mapped
/// hypnogram of its sleep cycles, a stage breakdown, the list of recent
/// sessions (so naps are easy to spot), and a last-7-nights trend.
class SleepTab extends StatefulWidget {
  const SleepTab({super.key});

  @override
  State<SleepTab> createState() => _SleepTabState();
}

class _SleepTabState extends State<SleepTab> {
  // The chosen session is tracked by its start time (the SleepDay objects are
  // rebuilt on every data refresh, so we can't hold a reference).
  DateTime? _selectedStart;

  // ---- formatting helpers --------------------------------------------------

  static String _fmtMinutes(int minutes) {
    if (minutes < 60) return '${minutes}m';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return m == 0 ? '${h}h' : '${h}h ${m}m';
  }

  static String clock(DateTime t) {
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m ${t.hour < 12 ? 'AM' : 'PM'}';
  }

  static const List<String> _weekdayInitials = [
    'M', 'T', 'W', 'T', 'F', 'S', 'S',
  ];

  String _dateLabel(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final d = DateTime(date.year, date.month, date.day);
    final diff = today.difference(d).inDays;
    if (diff <= 0) return 'Today';
    if (diff == 1) return 'Last night';
    if (diff < 7) return '$diff nights ago';
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${months[date.month - 1]} ${date.day}';
  }

  // ---- session selection ---------------------------------------------------

  /// Sessions ending within ~40h of the most recent one (last night + the
  /// surrounding day's naps).
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

  /// The night's main sleep = the longest recent session.
  SleepDay? _main(List<SleepDay> recent) {
    if (recent.isEmpty) return null;
    return recent
        .reduce((a, b) => a.totalSleepMinutes >= b.totalSleepMinutes ? a : b);
  }

  /// One representative (longest) session per calendar date, for the trend.
  List<SleepDay> _perNight(List<SleepDay> days) {
    final byDate = <String, SleepDay>{};
    for (final d in days) {
      final key = '${d.date.year}-${d.date.month}-${d.date.day}';
      final cur = byDate[key];
      if (cur == null || d.totalSleepMinutes > cur.totalSleepMinutes) {
        byDate[key] = d;
      }
    }
    final list = byDate.values.toList()
      ..sort((a, b) => a.date.compareTo(b.date));
    return list;
  }

  // ---- build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final ble = context.watch<BLEManager>();
    final days = ble.activityStore.computeSleepDays();
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

    return CustomScrollView(
      slivers: [
        SliverAppBar(
          pinned: true,
          expandedHeight: 150,
          backgroundColor: AppColors.scaffold,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          automaticallyImplyLeading: false,
          flexibleSpace: FlexibleSpaceBar(
            background: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg,
                    AppSpacing.lg, AppSpacing.md),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Spacer(),
                    Text('Sleep', style: AppText.h1),
                    const SizedBox(height: 2),
                    Text(
                      selected != null
                          ? _dateLabel(selected.date)
                          : 'Sleep tracking',
                      style: AppText.label,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (selected == null)
          _buildEmptyState()
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                const SizedBox(height: AppSpacing.sm),
                _HeroCard(day: selected, dateLabel: _dateLabel(selected.date)),
                const SizedBox(height: AppSpacing.lg),
                _HypnogramTimeline(day: selected),
                const SizedBox(height: AppSpacing.lg),
                const SectionHeader('Stages'),
                _StageBreakdown(day: selected),
                if (recent.length > 1) ...[
                  const SizedBox(height: AppSpacing.xl),
                  const SectionHeader('Recent sessions'),
                  _SessionsList(
                    sessions: recent,
                    selectedStart: selected.startTime,
                    onSelect: (d) =>
                        setState(() => _selectedStart = d.startTime),
                  ),
                ],
                const SizedBox(height: AppSpacing.xl),
                _Last7NightsChart(days: _perNight(days)),
              ]),
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 96)),
      ],
    );
  }

  Widget _buildEmptyState() {
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
                Text(
                  'Wear your band to bed to see your sleep stages here.',
                  style: AppText.body.copyWith(color: AppColors.inkMuted),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

// ===========================================================================
// Hero card
// ===========================================================================

class _HeroCard extends StatelessWidget {
  final SleepDay day;
  final String dateLabel;
  const _HeroCard({required this.day, required this.dateLabel});

  ({String text, Color color, IconData icon}) _quality(SleepDay d) {
    if (d.isNap) {
      return (text: 'Nap', color: AppColors.sleep, icon: Icons.wb_twilight_rounded);
    }
    final m = d.totalSleepMinutes;
    if (m >= 7 * 60) {
      return (text: 'Great', color: AppColors.success, icon: Icons.auto_awesome_rounded);
    }
    if (m >= 5 * 60) {
      return (text: 'Fair', color: AppColors.warning, icon: Icons.auto_awesome_rounded);
    }
    return (text: 'Short', color: AppColors.danger, icon: Icons.auto_awesome_rounded);
  }

  @override
  Widget build(BuildContext context) {
    final q = _quality(day);
    final start = day.startTime;
    final end = day.endTime;

    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: AppColors.sleep.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.bedtime_rounded,
                    color: AppColors.sleep, size: 20),
              ),
              const SizedBox(width: AppSpacing.md),
              Text(day.isNap ? 'Nap' : dateLabel, style: AppText.label),
              const Spacer(),
              _Pill(text: q.text, color: q.color, icon: q.icon),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(day.durationString, style: AppText.metricHero),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Row(
            children: [
              Text('Time asleep', style: AppText.label),
              if (start != null && end != null) ...[
                const SizedBox(width: AppSpacing.sm),
                Container(
                  width: 3,
                  height: 3,
                  decoration: const BoxDecoration(
                    color: AppColors.inkFaint,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  '${_SleepTabState.clock(start)} – ${_SleepTabState.clock(end)}',
                  style: AppText.label,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String text;
  final Color color;
  final IconData icon;
  const _Pill({required this.text, required this.color, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(AppRadii.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 5),
          Text(text,
              style: AppText.caption
                  .copyWith(color: color, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

// ===========================================================================
// Hypnogram timeline — stages mapped over clock time
// ===========================================================================

class _HypnogramTimeline extends StatelessWidget {
  final SleepDay day;
  const _HypnogramTimeline({required this.day});

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
                Text(
                  '${_SleepTabState.clock(start)} – ${_SleepTabState.clock(end)}',
                  style: AppText.caption.copyWith(color: AppColors.inkMuted),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          if (!hasData)
            const SizedBox(
              height: 60,
              child: ChartEmpty(
                  message: 'No stage data', icon: Icons.bedtime_rounded),
            )
          else
            SizedBox(
              height: 156,
              child: CustomPaint(
                painter: _HypnoPainter(
                  intervals: day.intervals,
                  start: start,
                  end: end,
                ),
                child: const SizedBox.expand(),
              ),
            ),
        ],
      ),
    );
  }
}

class _HypnoPainter extends CustomPainter {
  final List<SleepInterval> intervals;
  final DateTime start;
  final DateTime end;
  _HypnoPainter({
    required this.intervals,
    required this.start,
    required this.end,
  });

  // Rows top→bottom: Awake, REM, Light, Deep (deeper = lower).
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
    const padL = 42.0, padB = 18.0, padT = 4.0, padR = 6.0;
    final plot = Rect.fromLTRB(padL, padT, size.width - padR, size.height - padB);
    final spanMs = end.difference(start).inMilliseconds;
    if (spanMs <= 0 || plot.width <= 0) return;

    const rows = 4;
    final rowH = plot.height / rows;
    double rowCenter(int lvl) => plot.top + rowH * lvl + rowH / 2;
    double xAt(DateTime t) =>
        plot.left + (t.difference(start).inMilliseconds / spanMs) * plot.width;

    // Row gridlines + Y labels.
    final grid = Paint()
      ..color = AppColors.divider
      ..strokeWidth = 1;
    for (var i = 0; i < rows; i++) {
      final cy = rowCenter(i);
      canvas.drawLine(Offset(plot.left, cy), Offset(plot.right, cy), grid);
      _text(canvas, _rowLabels[i], Offset(0, cy - 6),
          color: _rowColors[i], size: 10, weight: FontWeight.w700);
    }

    // Hour gridlines + time labels.
    final stepHours = spanMs > 6 * 3600 * 1000 ? 2 : 1;
    final hourPaint = Paint()
      ..color = AppColors.divider.withValues(alpha: 0.6)
      ..strokeWidth = 1;
    var tick = DateTime(start.year, start.month, start.day, start.hour)
        .add(const Duration(hours: 1));
    while (tick.isBefore(end)) {
      final x = xAt(tick);
      canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), hourPaint);
      _text(canvas, _hourLabel(tick), Offset(x - 12, plot.bottom + 4),
          color: AppColors.inkFaint, size: 9);
      tick = tick.add(Duration(hours: stepHours));
    }
    // Bedtime / wake markers at the edges.
    _text(canvas, _hourLabel(start), Offset(plot.left - 4, plot.bottom + 4),
        color: AppColors.inkMuted, size: 9, weight: FontWeight.w700);
    _text(canvas, _hourLabel(end), Offset(plot.right - 30, plot.bottom + 4),
        color: AppColors.inkMuted, size: 9, weight: FontWeight.w700);

    // Stage segments (positioned by real time) + connectors between them.
    final segH = rowH * 0.5;
    int? prevLvl;
    for (final iv in intervals) {
      final lvl = _level(iv.stage);
      final x0 = xAt(iv.startTime);
      var x1 = xAt(iv.endTime);
      if (x1 < x0 + 2) x1 = x0 + 2;
      final cy = rowCenter(lvl);

      if (prevLvl != null) {
        canvas.drawLine(
          Offset(x0, rowCenter(prevLvl)),
          Offset(x0, cy),
          Paint()
            ..color = AppColors.sleepLight.withValues(alpha: 0.45)
            ..strokeWidth = 2,
        );
      }
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTRB(x0, cy - segH / 2, x1, cy + segH / 2),
        const Radius.circular(3),
      );
      canvas.drawRRect(rect, Paint()..color = _stageColor(iv.stage));
      prevLvl = lvl;
    }
  }

  Color _stageColor(SleepStage s) {
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
      {required Color color, required double size, FontWeight weight = FontWeight.w600}) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(color: color, fontSize: size, fontWeight: weight),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(covariant _HypnoPainter old) =>
      old.intervals != intervals || old.start != start || old.end != end;
}

// ===========================================================================
// Recent sessions list (naps + night, tappable)
// ===========================================================================

class _SessionsList extends StatelessWidget {
  final List<SleepDay> sessions; // chronological
  final DateTime? selectedStart;
  final ValueChanged<SleepDay> onSelect;
  const _SessionsList({
    required this.sessions,
    required this.selectedStart,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final ordered = [...sessions]
      ..sort((a, b) =>
          (b.startTime ?? b.date).compareTo(a.startTime ?? a.date));
    return Column(
      children: [
        for (final s in ordered) ...[
          _SessionRow(
            day: s,
            selected: s.startTime == selectedStart,
            onTap: () => onSelect(s),
          ),
          if (s != ordered.last) const SizedBox(height: AppSpacing.sm),
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
    final color = nap ? AppColors.sleepLight : AppColors.sleep;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.lg),
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.md),
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
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(
                  nap ? Icons.wb_twilight_rounded : Icons.bedtime_rounded,
                  color: color,
                  size: 19,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(nap ? 'Nap' : 'Night sleep', style: AppText.title),
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
                  style: AppText.metricSm.copyWith(fontSize: 18)),
            ],
          ),
        ),
      ),
    );
  }
}

// ===========================================================================
// Stage breakdown (2x2 grid)
// ===========================================================================

class _StageBreakdown extends StatelessWidget {
  final SleepDay day;
  const _StageBreakdown({required this.day});

  @override
  Widget build(BuildContext context) {
    final total = day.totalSleepMinutes + day.totalAwakeMinutes;
    final cells = <Widget>[
      _StageCell(
        label: 'Deep',
        color: AppColors.sleepDeep,
        icon: Icons.dark_mode_rounded,
        minutes: day.totalDeepMinutes,
        total: total,
      ),
      _StageCell(
        label: 'Light',
        color: AppColors.sleepLight,
        icon: Icons.nights_stay_rounded,
        minutes: day.totalLightMinutes,
        total: total,
      ),
      _StageCell(
        label: 'REM',
        color: AppColors.sleepRem,
        icon: Icons.remove_red_eye_rounded,
        minutes: day.totalRemMinutes,
        total: total,
      ),
      _StageCell(
        label: 'Awake',
        color: AppColors.sleepAwake,
        icon: Icons.wb_sunny_rounded,
        minutes: day.totalAwakeMinutes,
        total: total,
      ),
    ];

    return Column(
      children: [
        Row(
          children: [
            Expanded(child: cells[0]),
            const SizedBox(width: AppSpacing.md),
            Expanded(child: cells[1]),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        Row(
          children: [
            Expanded(child: cells[2]),
            const SizedBox(width: AppSpacing.md),
            Expanded(child: cells[3]),
          ],
        ),
      ],
    );
  }
}

class _StageCell extends StatelessWidget {
  final String label;
  final Color color;
  final IconData icon;
  final int minutes;
  final int total;
  const _StageCell({
    required this.label,
    required this.color,
    required this.icon,
    required this.minutes,
    required this.total,
  });

  @override
  Widget build(BuildContext context) {
    final pct = total > 0 ? (minutes / total * 100).round() : 0;
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
              const Spacer(),
              Text('$pct%', style: AppText.caption.copyWith(color: color)),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Text(_SleepTabState._fmtMinutes(minutes), style: AppText.metricSm),
          const SizedBox(height: 2),
          Text(label, style: AppText.label),
        ],
      ),
    );
  }
}

// ===========================================================================
// Last 7 nights bar chart
// ===========================================================================

class _Last7NightsChart extends StatelessWidget {
  final List<SleepDay> days;
  const _Last7NightsChart({required this.days});

  @override
  Widget build(BuildContext context) {
    final recent = days.length <= 7 ? days : days.sublist(days.length - 7);

    if (recent.length < 2) {
      return const ChartCard(
        title: 'Last 7 nights',
        height: 180,
        child: ChartEmpty(
            message: 'Not enough nights yet', icon: Icons.bedtime_rounded),
      );
    }

    final maxMinutes = recent
        .map((d) => d.totalSleepMinutes)
        .fold<int>(0, (a, b) => a > b ? a : b);
    final maxY = (maxMinutes <= 0 ? 60 : maxMinutes) * 1.2;

    return ChartCard(
      title: 'Last 7 nights',
      height: 180,
      child: BarChart(
        BarChartData(
          alignment: BarChartAlignment.spaceAround,
          maxY: maxY,
          minY: 0,
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            getDrawingHorizontalLine: (value) =>
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
                  final letter =
                      _SleepTabState._weekdayInitials[(wd - 1).clamp(0, 6)];
                  return Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.sm),
                    child: Text(letter,
                        style: AppText.caption
                            .copyWith(color: AppColors.inkFaint)),
                  );
                },
              ),
            ),
          ),
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              getTooltipColor: (group) => AppColors.ink,
              tooltipRoundedRadius: AppRadii.sm,
              getTooltipItem: (group, groupIndex, rod, rodIndex) {
                return BarTooltipItem(
                  _SleepTabState._fmtMinutes(rod.toY.round()),
                  AppText.caption.copyWith(color: Colors.white),
                );
              },
            ),
          ),
          barGroups: [
            for (var i = 0; i < recent.length; i++)
              BarChartGroupData(
                x: i,
                barRods: [
                  BarChartRodData(
                    toY: recent[i].totalSleepMinutes.toDouble(),
                    color: AppColors.sleep,
                    width: 16,
                    borderRadius:
                        const BorderRadius.vertical(top: Radius.circular(6)),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
