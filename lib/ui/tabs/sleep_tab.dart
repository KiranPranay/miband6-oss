import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/analysis_cache.dart';
import '../../core/sleep_regularity.dart';
import '../../core/ble_manager.dart';
import '../../core/activity_sample.dart';
import '../../core/sleep_analysis.dart';
import '../../core/sleep_analyzer.dart';
import '../../core/sleep_audio_controller.dart';
import '../../storage/snore_store.dart';
import '../sleep_audio/snore_tracking_screen.dart';
import '../widgets/coming_soon.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/app_card.dart';
import '../widgets/count_up_text.dart';
import '../widgets/section_header.dart';
import '../widgets/ledger.dart';
import '../widgets/illustrations.dart';
import '../widgets/tab_header.dart';

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
    'Mon',
    'Tue',
    'Wed',
    'Thu',
    'Fri',
    'Sat',
    'Sun',
  ];
  static const _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
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
    final ble = context.read<BLEManager>();
    // This screen renders stored history only — no live values — so it rebuilds
    // solely when the stored data changes. Previously a streaming heart rate
    // rebuilt all ~2 000 lines of it several times a second (findings-15).
    return ListenableBuilder(
      listenable: Listenable.merge([
        ble.activityStore.revisionListenable,
        ble.fetchingListenable,
      ]),
      builder: (context, _) => _buildContent(context, ble),
    );
  }

  Widget _buildContent(BuildContext context, BLEManager ble) {
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

    // If the most recent sleep-day has no night, say what the band did record
    // rather than promoting a nap to the top of the screen.
    RestOnlyNight? restOnly;
    if (selected == null || selected.isNap) {
      final now = DateTime.now();
      final latestDay = SleepAnalyzer.sleepDayFor(now);
      final candidates = [
        latestDay,
        latestDay.subtract(const Duration(days: 1))
      ];
      for (final d in candidates) {
        restOnly = SleepAnalyzer.restOnlyNight(
            store.samples, store.hrReadings, d,
            sessions: days);
        if (restOnly != null) break;
      }
    }

    // Computed once here, not inside the sliver list literal below — that
    // literal is built eagerly on every rebuild, so the call ran a full
    // whole-history sleep pass per frame while re-deriving sessions the memo on
    // line above had already produced.
    final regularity = SleepRegularity.compute(store.samples,
        hr: store.hrReadings, sessions: days);

    final analysis = selected == null
        ? null
        : AnalysisCache.sleep(store, session: selected, allDays: days);

    return CustomScrollView(
      slivers: [
        TabHeaderSliver(
          title: 'Sleep',
          subtitle: selected != null
              ? (selected.isNap ? 'Nap' : _nightLabel(selected.date))
              : 'Sleep tracking',
          subtitleIcon: Icons.bedtime_rounded,
          subtitleIconColor: AppColors.sleep,
        ),
        if (selected == null || analysis == null)
          _emptyState()
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                const SizedBox(height: AppSpacing.sm),
                // A nap gets a nap card: duration, efficiency and when — no
                // score ring, no rating, no 8-hour goal bar. Scoring a
                // 40-minute nap "Poor · 33/100 · 8% of goal" is a true sum
                // over the wrong thing.
                _NightNav(
                  days: days,
                  selected: selected,
                  onSelect: (d) => setState(() => _selectedStart = d.startTime),
                ),
                const SizedBox(height: AppSpacing.sm),
                if (restOnly != null) ...[
                  _RestOnlyCard(night: restOnly),
                  const SizedBox(height: AppSpacing.lg),
                ],
                selected.isNap
                    ? _NapHero(a: analysis, day: selected)
                    : _ScoreHero(a: analysis, day: selected),
                const SizedBox(height: AppSpacing.lg),
                // The night itself, right under the number — the timeline is
                // the evidence for everything above it and everything below.
                _TimelineCard(day: selected),
                const SizedBox(height: AppSpacing.lg),
                _InsightsCard(insights: analysis.insights),
                // Stages, ranges and "vs your average" are defined for a
                // night. On a nap they rendered "Deep 0m · Below range ·
                // Healthy 8m-14m", every part of which is meaningless.
                if (!selected.isNap) ...[
                  const SectionHeader('Sleep stages'),
                  const _StageCaveat(),
                  if (!analysis.hasPersonalBaseline) ...[
                    const SizedBox(height: AppSpacing.sm),
                    _BaselineNote(a: analysis),
                  ],
                  const SizedBox(height: AppSpacing.md),
                  _StageList(a: analysis),
                ],
                const SectionHeader('Metrics'),
                _MetricsLedger(a: analysis, day: selected),
                const SizedBox(height: AppSpacing.lg),
                if (analysis.recommendations.isNotEmpty)
                  _RecommendationsCard(recs: analysis.recommendations),
                const SizedBox(height: AppSpacing.lg),
                const _AiAnalysisCard(),
                const SectionHeader('Sleep sounds'),
                const _SnoringSection(),
                const SectionHeader('Sleep regularity'),
                _RegularityCard(result: regularity),
                const SectionHeader('Recent nights'),
                _WeeklySummary(a: analysis, nights: _perNight(days)),
                const SizedBox(height: AppSpacing.sm),
                _WeekChart(nights: _perNight(days)),
                if (recent.length > 1) ...[
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
        const SliverNavClearance(),
      ],
    );
  }

  Widget _emptyState() {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      sliver: SliverList(
        delegate: SliverChildListDelegate([
          const SizedBox(height: AppSpacing.sm),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.xxl),
            child: Column(
              children: [
                const SizedBox(height: AppSpacing.xl),
                const MoonAndStars(size: 96),
                const SizedBox(height: AppSpacing.xl),
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

/// Step between recorded sessions without scrolling to the log.
///
/// The only way to look at a different night used to be to scroll to the
/// bottom of the screen and tap it in the list, then scroll back up. Two
/// chevrons and the night's name, at the top, next to the number they change.
class _NightNav extends StatelessWidget {
  final List<SleepDay> days;
  final SleepDay selected;
  final ValueChanged<SleepDay> onSelect;
  const _NightNav(
      {required this.days, required this.selected, required this.onSelect});

  static const _wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _mo = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  @override
  Widget build(BuildContext context) {
    final sorted = [...days]
      ..sort((a, b) => (a.startTime ?? a.date).compareTo(b.startTime ?? b.date));
    final i = sorted.indexWhere((d) => d.startTime == selected.startTime);
    final prev = i > 0 ? sorted[i - 1] : null;
    final next = i >= 0 && i < sorted.length - 1 ? sorted[i + 1] : null;
    final t = selected.startTime ?? selected.date;
    final label =
        '${_wd[t.weekday - 1]} ${t.day} ${_mo[t.month - 1]}'
        '${selected.isNap ? ' · nap' : ''}';
    return Row(
      children: [
        IconButton(
          onPressed: prev == null ? null : () => onSelect(prev),
          icon: const Icon(Icons.chevron_left_rounded),
          tooltip: 'Earlier',
          color: AppColors.inkMuted,
        ),
        Expanded(
          child: Text(label,
              textAlign: TextAlign.center,
              style: AppText.label.copyWith(
                  color: AppColors.ink, fontWeight: FontWeight.w700)),
        ),
        IconButton(
          onPressed: next == null ? null : () => onSelect(next),
          icon: const Icon(Icons.chevron_right_rounded),
          tooltip: 'Later',
          color: AppColors.inkMuted,
        ),
      ],
    );
  }
}

/// A night the band was worn but could not classify. Nothing here is a
/// sleep figure; it is the evidence, stated as evidence.
class _RestOnlyCard extends StatelessWidget {
  final RestOnlyNight night;
  const _RestOnlyCard({required this.night});

  @override
  Widget build(BuildContext context) {
    final n = night;
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.nights_stay_outlined, color: AppColors.sleep),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text('Last night — restless, not staged',
                    style: AppText.title),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'The band was on your wrist and your heart rate was down from '
            '${_SleepTabState.clock(n.start)} to ${_SleepTabState.clock(n.end)} '
            '(${_SleepTabState.fmtMinutes(n.restMinutes)} at rest), but you '
            'moved through most of it and the band flagged only '
            '${_SleepTabState.fmtMinutes(n.flaggedMinutes)} as sleep. '
            'That is not enough to call it sleep, so there is no score.',
            style:
                AppText.body.copyWith(color: AppColors.inkMuted, height: 1.4),
          ),
        ],
      ),
    );
  }
}

class _NapHero extends StatelessWidget {
  final SleepAnalysis a;
  final SleepDay day;
  const _NapHero({required this.a, required this.day});

  @override
  Widget build(BuildContext context) {
    final start = day.startTime, end = day.endTime;
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.sleepSoft,
                  borderRadius: BorderRadius.circular(AppRadii.md),
                ),
                child: Icon(Icons.wb_twilight_rounded, color: AppColors.sleep),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Nap',
                        style: AppText.label.copyWith(
                            color: AppColors.inkMuted,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
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
          const SizedBox(height: AppSpacing.md),
          Text(
            [
              if (start != null && end != null)
                '${_SleepTabState.clock(start)} – ${_SleepTabState.clock(end)}',
              '${a.efficiencyPct}% of the time in bed',
            ].join(' · '),
            style: AppText.caption.copyWith(color: AppColors.inkMuted),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Naps are not scored — the score, goal and stage ranges are '
            'defined for a night.',
            style: AppText.caption.copyWith(color: AppColors.inkFaint),
          ),
        ],
      ),
    );
  }
}

class _ScoreHero extends StatelessWidget {
  final SleepAnalysis a;
  final SleepDay day;
  const _ScoreHero({required this.a, required this.day});

  @override
  Widget build(BuildContext context) {
    // Colour hierarchy: the score has ONE identity colour (sleep indigo); the
    // rating word carries the semantic quality tint; the goal bar uses a
    // distinct colour — so green no longer dominates the whole card.
    final ratingClr = _SleepTabState.ratingColor(a.score);
    final goalPct = a.goalPct.clamp(0, 100);
    final start = day.startTime, end = day.endTime;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The night as an arc: bedtime at one horizon, waking at the other,
          // the moon at the midpoint. It is the span, not decoration.
          const SkyArc(progress: 0.5, night: true),
          if (start != null && end != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(_SleepTabState.clock(start), style: AppText.caption),
                  Text(_SleepTabState.clock(end), style: AppText.caption),
                ],
              ),
            ),
          const SizedBox(height: AppSpacing.lg),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _ScoreRing(score: a.score, color: AppColors.sleep),
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
                        style: AppText.h1.copyWith(color: ratingClr)),
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
            color: AppColors.primary,
          ),
          if (a.vsYesterdayMin != null) ...[
            const SizedBox(height: AppSpacing.md),
            _DeltaLine(deltaMin: a.vsYesterdayMin!),
          ],
          const SizedBox(height: AppSpacing.lg),
          Divider(height: 1, color: AppColors.divider),
          const SizedBox(height: AppSpacing.md),
          _ScoreBreakdown(components: a.scoreComponents),
        ],
      ),
    );
  }
}

/// Shows the weighted sub-scores that make up the overall score, so "86" next to
/// "Deep 11m" is explained rather than mistrusted.
class _ScoreBreakdown extends StatelessWidget {
  final List<ScoreComponent> components;
  const _ScoreBreakdown({required this.components});

  Color _barColor(int sub) {
    if (sub >= 80) return AppColors.success;
    if (sub >= 50) return AppColors.warning;
    return AppColors.danger;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('What makes up this score',
            style: AppText.caption.copyWith(
                color: AppColors.inkMuted, fontWeight: FontWeight.w700)),
        const SizedBox(height: AppSpacing.sm),
        for (var i = 0; i < components.length; i++) ...[
          if (i > 0) const SizedBox(height: AppSpacing.sm),
          _ScoreRow(c: components[i], color: _barColor(components[i].score)),
        ],
      ],
    );
  }
}

class _ScoreRow extends StatelessWidget {
  final ScoreComponent c;
  final Color color;
  const _ScoreRow({required this.c, required this.color});

  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.reduced(context);
    final frac = (c.score / 100).clamp(0.0, 1.0);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 92,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(c.label,
                  style: AppText.label.copyWith(color: AppColors.ink)),
              Text('${(c.weight * 100).round()}% weight',
                  style: AppText.caption
                      .copyWith(color: AppColors.inkFaint, fontSize: 10)),
            ],
          ),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadii.pill),
            child: SizedBox(
              height: 7,
              child: Stack(children: [
                Container(color: AppColors.surfaceAlt),
                LayoutBuilder(builder: (context, cc) {
                  final w = cc.maxWidth * frac;
                  final bar = Container(
                      width: w,
                      decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(AppRadii.pill)));
                  if (reduced) return bar;
                  return TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: w),
                    duration: AppMotion.slow,
                    curve: AppMotion.ease,
                    builder: (context, ww, _) => Container(
                        width: ww,
                        decoration: BoxDecoration(
                            color: color,
                            borderRadius:
                                BorderRadius.circular(AppRadii.pill))),
                  );
                }),
              ]),
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        SizedBox(
          width: 38,
          child: Text('${c.score}%',
              textAlign: TextAlign.right,
              style: AppText.label
                  .copyWith(color: AppColors.ink, fontWeight: FontWeight.w800)),
        ),
      ],
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
                      style:
                          AppText.caption.copyWith(color: AppColors.inkFaint)),
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
              ? 'About the same as yesterday'
              : 'You slept $mag ${up ? 'longer' : 'shorter'} than yesterday',
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

/// Deliberate "coming soon" placeholder for the AI summary the review wants.
/// NOT a templated sentence pretending to be AI — a clearly-labelled preview.
class _AiAnalysisCard extends StatelessWidget {
  const _AiAnalysisCard();

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadii.lg),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ComingSoonScreen(
            title: 'AI Analysis',
            description:
                'Personalized AI summaries of your sleep trends — in development.',
            icon: Icons.auto_awesome_rounded,
            gradient: [AppColors.primary, AppColors.sleep],
          ),
        )),
        child: Container(
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
            border:
                Border.all(color: AppColors.primary.withValues(alpha: 0.18)),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.auto_awesome_rounded,
                    color: AppColors.primary, size: 20),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text('AI Analysis', style: AppText.title),
                        const SizedBox(width: AppSpacing.sm),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: AppColors.primary.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(AppRadii.pill),
                          ),
                          child: Text('SOON',
                              style: AppText.caption.copyWith(
                                  color: AppColors.primary,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.5,
                                  fontSize: 10)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Personalized summaries of your sleep trends — in development.',
                      style:
                          AppText.caption.copyWith(color: AppColors.inkMuted),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: AppColors.inkFaint),
            ],
          ),
        ),
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
                Text(
                    '${_SleepTabState.clock(start)} – ${_SleepTabState.clock(end)}',
                    style: AppText.caption.copyWith(color: AppColors.inkMuted)),
            ],
          ),
          if (hasData) ...[
            const SizedBox(height: AppSpacing.sm),
            _StageHeader(day: day),
          ],
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
              height: 240,
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

/// Scannable stage totals above the chart, so the split is readable without
/// interpreting the hypnogram.
class _StageHeader extends StatelessWidget {
  final SleepDay day;
  const _StageHeader({required this.day});

  @override
  Widget build(BuildContext context) {
    final total = day.totalSleepMinutes;
    int pct(int m) => total > 0 ? (m / total * 100).round() : 0;
    Widget chip(Color c, String label, int m) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                  color: c, borderRadius: BorderRadius.circular(2)),
            ),
            const SizedBox(width: 5),
            Text('$label ${_SleepTabState.fmtMinutes(m)}',
                style: AppText.caption.copyWith(
                    color: AppColors.ink, fontWeight: FontWeight.w700)),
            const SizedBox(width: 3),
            Text('(${pct(m)}%)',
                style: AppText.caption.copyWith(color: AppColors.inkMuted)),
          ],
        );
    return Wrap(
      spacing: AppSpacing.md,
      runSpacing: AppSpacing.xs,
      children: [
        // Deep is an estimate (findings-25) and the chip says so. Were staging
        // ever disabled again there is no chip at all: "Deep 0m" would be a
        // claim about the user's night, not about what the app can measure.
        // Summed from the intervals the timeline actually draws, not from the
        // SleepDay totals: a nap keeps its minutes in `totalNapMinutes`, so
        // the legend read "Light 0m" under a chart full of light-sleep blocks.
        if (SleepAnalyzer.kDeepStagingEnabled)
          chip(AppColors.sleepDeep, 'Deep (est.)',
              _stageMinutes(day, SleepStage.deep)),
        chip(
            AppColors.sleepLight,
            SleepAnalyzer.kDeepStagingEnabled ? 'Light' : 'Asleep',
            _stageMinutes(day, SleepStage.light)),
        if (day.totalRemMinutes > 0)
          chip(AppColors.sleepRem, 'REM', day.totalRemMinutes),
      ],
    );
  }
}

int _stageMinutes(SleepDay d, SleepStage st) => d.intervals
    .where((i) => i.stage == st)
    .fold<int>(0, (a, i) => a + i.durationMinutes);

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
              decoration: BoxDecoration(
                  color: c, borderRadius: BorderRadius.circular(3)),
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
        // No REM: this band cannot measure it (findings-09).
        if (SleepAnalyzer.kDeepStagingEnabled) ...[
          dot(AppColors.sleepLight, 'Light'),
          dot(AppColors.sleepDeep, 'Deep (est.)'),
        ] else
          dot(AppColors.sleepLight, 'Asleep'),
      ],
    );
  }
}

class _HypnoPainter extends CustomPainter {
  final List<SleepInterval> intervals;
  final DateTime start;
  final DateTime end;
  _HypnoPainter(
      {required this.intervals, required this.start, required this.end});

  int _level(SleepStage s) {
    switch (s) {
      case SleepStage.awake:
        return 0;
      case SleepStage.rem:
        // Never reported on this band (findings-09); if a stray interval ever
        // carried it, draw it in the light lane rather than invent a row.
        return SleepAnalyzer.kDeepStagingEnabled ? 1 : 1;
      case SleepStage.light:
      case SleepStage.nap:
        return SleepAnalyzer.kDeepStagingEnabled ? 1 : 1;
      case SleepStage.deep:
        return SleepAnalyzer.kDeepStagingEnabled ? 2 : 1;
    }
  }

  // No REM lane: this band cannot measure it (findings-09), and an empty row
  // labelled "REM" reads as "you had none" rather than "not measured". Three
  // lanes with deep enabled, two without.
  static List<String> get _rowLabels => SleepAnalyzer.kDeepStagingEnabled
      ? const ['Awake', 'Light', 'Deep (est.)']
      : const ['Awake', 'Asleep'];
  static List<Color> get _rowColors => SleepAnalyzer.kDeepStagingEnabled
      ? [
          AppColors.sleepAwake,
          AppColors.sleepLight,
          AppColors.sleepDeep,
        ]
      : [AppColors.sleepAwake, AppColors.sleepLight];

  @override
  void paint(Canvas canvas, Size size) {
    const padL = 46.0, padB = 20.0, padT = 6.0, padR = 8.0;
    final plot =
        Rect.fromLTRB(padL, padT, size.width - padR, size.height - padB);
    final spanMs = end.difference(start).inMilliseconds;
    if (spanMs <= 0 || plot.width <= 0) return;

    final rows = _rowLabels.length;
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

    // Short spans (a nap) get minute-resolution labels; a 57-minute nap used
    // to read "8p · 9p · 9p". Long spans keep hour ticks, every 2 h past 6 h.
    final shortSpan = spanMs < 3 * 3600 * 1000;
    final stepHours = spanMs > 6 * 3600 * 1000 ? 2 : 1;
    final hourPaint = Paint()
      ..color = AppColors.divider.withValues(alpha: 0.6)
      ..strokeWidth = 1;
    double? lastTickX;
    if (!shortSpan) {
      var tick = DateTime(start.year, start.month, start.day, start.hour)
          .add(const Duration(hours: 1));
      while (tick.isBefore(end)) {
        final x = xAt(tick);
        // Skip a tick that would sit on top of the start or end label.
        if (x - plot.left > 28 && plot.right - x > 28) {
          canvas.drawLine(
              Offset(x, plot.top), Offset(x, plot.bottom), hourPaint);
          _text(canvas, _hourLabel(tick), Offset(x - 13, plot.bottom + 5),
              color: AppColors.inkFaint, size: 10);
          lastTickX = x;
        }
        tick = tick.add(Duration(hours: stepHours));
      }
    }
    final startLabel = shortSpan ? _clockLabel(start) : _hourLabel(start);
    final endLabel = shortSpan ? _clockLabel(end) : _hourLabel(end);
    _text(canvas, startLabel, Offset(plot.left - 6, plot.bottom + 5),
        color: AppColors.inkMuted, size: 10, weight: FontWeight.w700);
    if (lastTickX == null || plot.right - lastTickX > 40) {
      _text(canvas, endLabel,
          Offset(plot.right - (shortSpan ? 44 : 32), plot.bottom + 5),
          color: AppColors.inkMuted, size: 10, weight: FontWeight.w700);
    }

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

  String _clockLabel(DateTime t) {
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    return '$h:${t.minute.toString().padLeft(2, '0')}${t.hour < 12 ? 'a' : 'p'}';
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

/// Honest disclosure: MB6 has no dedicated sleep-session stream and doesn't
/// track REM, so deep/light here are estimates from the band's coarse data.
class _StageCaveat extends StatelessWidget {
  const _StageCaveat();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(AppRadii.md),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded, size: 15, color: AppColors.inkMuted),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              SleepAnalyzer.kDeepStagingEnabled
                  ? 'Deep sleep is estimated from heart-rate dips and '
                      'stillness, weighted towards the early night the way '
                      'slow-wave sleep is — not measured. REM is never shown: '
                      'this band cannot track it.'
                  : 'Asleep and awake only. Deep and REM are not shown: this '
                      'band cannot measure REM, and the deep-sleep estimate '
                      'was withdrawn after it turned out to pick minutes '
                      'spread evenly across the night, when real deep sleep '
                      'is concentrated early.',
              style: AppText.caption.copyWith(color: AppColors.inkMuted),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown until enough post-fix nights exist for a trustworthy personal
/// baseline. Explains why stages are compared to population ranges, not "your
/// average", so the absence of personalization is understood, not a bug.
class _BaselineNote extends StatelessWidget {
  final SleepAnalysis a;
  const _BaselineNote({required this.a});

  @override
  Widget build(BuildContext context) {
    final n = a.baselineNightCount;
    final need = a.baselineNightsNeeded;
    final frac = (n / need).clamp(0.0, 1.0);
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.insights_rounded, size: 15, color: AppColors.primary),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text('Building your baseline · $n of $need nights',
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
                  child: Container(color: AppColors.primary),
                ),
              ]),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Until then, stages are compared to general healthy ranges. Your '
            'personal "normal range" unlocks after $need clean nights.',
            style: AppText.caption.copyWith(color: AppColors.inkMuted),
          ),
        ],
      ),
    );
  }
}

class _StageList extends StatelessWidget {
  final SleepAnalysis a;
  const _StageList({required this.a});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < a.stages.length; i++) ...[
          if (i > 0) const SizedBox(height: AppSpacing.md),
          _StageRow(
              stat: a.stages[i],
              totalMin: a.durationMin,
              hasBaseline: a.hasPersonalBaseline),
        ],
      ],
    );
  }
}

class _StageRow extends StatelessWidget {
  final StageStat stat;
  final int totalMin;
  final bool hasBaseline;
  const _StageRow(
      {required this.stat, required this.totalMin, required this.hasBaseline});

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

  // Status is vs the population healthy *range* (always valid), not a personal
  // average — so it's labelled "range", and is honest before a baseline exists.
  ({String text, Color color}) get _status {
    switch (stat.status) {
      case MetricStatus.below:
        return (text: 'Below range', color: AppColors.warning);
      case MetricStatus.above:
        return (text: 'Above range', color: AppColors.primary);
      case MetricStatus.normal:
        return (text: 'In range', color: AppColors.success);
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
      color:
          Color.alphaBlend(_color.withValues(alpha: 0.045), AppColors.surface),
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
              // "Asleep" already reads as a stage name; "Light"/"Deep" need
              // the noun. Appending it unconditionally produced "Asleep sleep".
              Text(
                  SleepAnalyzer.kDeepStagingEnabled
                      ? '${stat.label} sleep'
                      : stat.label,
                  style: AppText.title),
              const Spacer(),
              // No verdict chip on the all-sleep bucket. Its range is 0-100 by
              // construction, so the chip would read "In range" every night —
              // a judgement with nothing behind it.
              if (SleepAnalyzer.kDeepStagingEnabled)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: s.color.withValues(alpha: 0.13),
                    borderRadius: BorderRadius.circular(AppRadii.pill),
                  ),
                  child: Text(s.text,
                      style: AppText.caption.copyWith(
                          color: s.color, fontWeight: FontWeight.w700)),
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
              // "vs your average" only once a real personal baseline exists.
              if (hasBaseline)
                Text(
                  stat.deltaVsAvg == 0
                      ? 'on your average'
                      : '${stat.deltaVsAvg > 0 ? '+' : '−'}${_SleepTabState.fmtMinutes(stat.deltaVsAvg.abs())} vs your avg',
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
          // No healthy band on the all-sleep bucket: its range is 0-100% by
          // construction, which renders as a meaningless "Healthy: 0m-<total>".
          if (SleepAnalyzer.kDeepStagingEnabled)
            Text(
                'Healthy: ${_SleepTabState.fmtMinutes(lowMin)}–${_SleepTabState.fmtMinutes(highMin)}',
                style: AppText.caption.copyWith(color: AppColors.inkFaint)),
        ],
      ),
    );
  }
}

// ===========================================================================
// Metrics grid (only what the band actually measures)
// ===========================================================================

class _MetricsLedger extends StatelessWidget {
  final SleepAnalysis a;
  final SleepDay day;
  const _MetricsLedger({required this.a, required this.day});

  @override
  Widget build(BuildContext context) {
    final samples = day.intervals.fold<int>(0, (n, i) => n + i.durationMinutes);
    return LedgerGroup(
      rows: [
        LedgerRow(
            label: 'Efficiency',
            value: '${a.efficiencyPct}',
            unit: '%',
            color: AppColors.activity,
            note: 'asleep while in bed'),
        LedgerRow(
            label: 'Time in bed',
            value: _SleepTabState.fmtMinutes(a.timeInBedMin),
            color: AppColors.sleep),
        LedgerRow(
            label: 'Wake-ups',
            value: '${a.wakeCount}',
            color: AppColors.sleepAwake,
            note: 'episodes of 5 minutes or more'),
        LedgerRow(
            label: 'Average heart rate',
            value: a.avgHr != null ? '${a.avgHr}' : '—',
            unit: a.avgHr != null ? 'bpm' : null,
            color: AppColors.heart),
        LedgerRow(
            label: 'Resting heart rate',
            value: a.restingHr != null ? '${a.restingHr}' : '—',
            unit: a.restingHr != null ? 'bpm' : null,
            color: AppColors.heart),
        LedgerRow(
            label: 'Blood oxygen',
            value: a.avgSpo2 != null ? '${a.avgSpo2}' : '—',
            unit: a.avgSpo2 != null ? '%' : null,
            color: AppColors.spo2,
            note: a.avgSpo2 == null ? 'no reading during this session' : null),
      ],
      evidence: '${fmtThousands(samples)} one-minute samples in this session',
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
              Icon(Icons.auto_awesome_rounded,
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
                    decoration: BoxDecoration(
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
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    return names[(d.weekday - 1).clamp(0, 6)];
  }

  static const _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  static String _shortDate(DateTime d) =>
      '${d.day} ${_months[(d.month - 1).clamp(0, 11)]}';

  /// "7 nights · 1 Jul – 10 Aug", or null when there is nothing to describe.
  ///
  /// A weekday alone is ambiguous the moment the pool covers more than a week —
  /// "Best night: Friday" could be any of several Fridays.
  String? get _span {
    final pool =
        nights.length <= 7 ? nights : nights.sublist(nights.length - 7);
    if (pool.isEmpty) return null;
    final first = pool.first.date;
    final last = pool.last.date;
    final count = '${pool.length} night${pool.length == 1 ? '' : 's'}';
    if (first.year == last.year &&
        first.month == last.month &&
        first.day == last.day) {
      return '$count · ${_shortDate(first)}';
    }
    return '$count · ${_shortDate(first)} – ${_shortDate(last)}';
  }

  @override
  Widget build(BuildContext context) {
    if (!a.hasPersonalBaseline) {
      return AppCard(
        child: Row(
          children: [
            Icon(Icons.calendar_month_rounded,
                size: 18, color: AppColors.primary),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(
                'Weekly averages appear once you have '
                '${a.baselineNightsNeeded} clean nights '
                '(${a.baselineNightCount} so far).',
                style: AppText.body.copyWith(color: AppColors.inkMuted),
              ),
            ),
          ],
        ),
      );
    }
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
        detail: a.consistencySpreadMin != null
            ? 'bedtimes varied by ${_SleepTabState.fmtMinutes(a.consistencySpreadMin!)}'
            : null,
      ),
      _MiniStat(
        label: 'Best night',
        value: a.bestNight != null ? _weekdayLong(a.bestNight!.date) : '—',
        detail: a.bestNight != null ? _shortDate(a.bestNight!.date) : null,
      ),
      _MiniStat(
        label: 'Lowest night',
        value: a.worstNight != null ? _weekdayLong(a.worstNight!.date) : '—',
        detail: a.worstNight != null ? _shortDate(a.worstNight!.date) : null,
      ),
    ];
    return AppCard(
      child: Column(
        children: [
          // Say which nights these are.
          //
          // The pool is the last N *recorded* nights, not the last N days — a
          // deliberate choice, because a personal baseline needs a minimum
          // number of nights rather than a calendar window. But the section was
          // headed "This week", and on real data those seven nights ran from
          // 1 July to 10 August. Every figure below was true of that pool and
          // false of the week, so the pool now names itself.
          if (_span != null) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: Text(_span!,
                  style: AppText.caption.copyWith(color: AppColors.inkFaint)),
            ),
            const SizedBox(height: AppSpacing.md),
          ],
          Row(children: [
            Expanded(child: stat[0]),
            Container(width: 1, height: 34, color: AppColors.divider),
            Expanded(child: stat[1]),
          ]),
          Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
            child: Divider(height: 1, color: AppColors.divider),
          ),
          Row(children: [
            Expanded(child: stat[2]),
            Container(width: 1, height: 34, color: AppColors.divider),
            Expanded(child: stat[3]),
          ]),
          if (a.sleepDebtMin != null) ...[
            Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
              child: Divider(height: 1, color: AppColors.divider),
            ),
            _SleepDebtRow(
                debtMin: a.sleepDebtMin!,
                nights: a.baselineNightCount,
                goalMin: a.goalMin),
          ],
        ],
      ),
    );
  }
}

/// Real, auditable: accumulated shortfall vs goal over the recent nights. Tap
/// reveals the math basis (no hidden "health score").
class _SleepDebtRow extends StatelessWidget {
  final int debtMin;
  final int nights;
  final int goalMin;
  const _SleepDebtRow(
      {required this.debtMin, required this.nights, required this.goalMin});

  void _explain(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Sleep debt'),
        content: Text(
          'The total sleep you fell short of your '
          '${_SleepTabState.fmtMinutes(goalMin)} goal across your last $nights '
          'nights — each night counts only the minutes below goal (never '
          'negative). Catch up gradually; you can’t fully "repay" it in one '
          'night.',
          style: AppText.body.copyWith(color: AppColors.inkMuted),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Got it')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final color = debtMin <= 60
        ? AppColors.success
        : (debtMin <= 240 ? AppColors.warning : AppColors.danger);
    return InkWell(
      onTap: () => _explain(context),
      borderRadius: BorderRadius.circular(AppRadii.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: Row(
          children: [
            Icon(Icons.account_balance_wallet_rounded, size: 18, color: color),
            const SizedBox(width: AppSpacing.sm),
            Text('Sleep debt',
                style: AppText.label.copyWith(color: AppColors.ink)),
            const SizedBox(width: 6),
            Icon(Icons.info_outline_rounded,
                size: 13, color: AppColors.inkFaint),
            const Spacer(),
            Text(
              debtMin <= 0 ? 'None' : _SleepTabState.fmtMinutes(debtMin),
              style: AppText.title.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  final String label;
  final String value;
  final String? detail;
  const _MiniStat({required this.label, required this.value, this.detail});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
      child: Column(
        children: [
          Text(label,
              style: AppText.caption.copyWith(color: AppColors.inkMuted)),
          const SizedBox(height: 4),
          Text(value, style: AppText.title),
          if (detail != null) ...[
            const SizedBox(height: 2),
            Text(detail!,
                textAlign: TextAlign.center,
                style: AppText.caption
                    .copyWith(color: AppColors.inkFaint, fontSize: 10)),
          ],
        ],
      ),
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

    // These are the last seven *recorded* nights, not the last seven days, so
    // when a night is missing they can span more than a week — and the axis then
    // reads "Wed Thu Fri Sat Sun Sun Mon", two bars with the same name and no
    // way to tell which is which. Fall back to dates whenever that happens.
    final weekdays = recent.map((d) => d.date.weekday).toList();
    final ambiguous = weekdays.toSet().length != weekdays.length;

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
                    final date = recent[i].date;
                    final text = ambiguous
                        ? '${date.day}/${date.month}'
                        : labels[(date.weekday - 1).clamp(0, 6)];
                    return Padding(
                      padding: const EdgeInsets.only(top: AppSpacing.sm),
                      child: Text(text,
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
                style: AppText.label.copyWith(
                    color: AppColors.inkMuted, fontWeight: FontWeight.w800)),
          ),
          for (final s in (groups[k]!
            ..sort((a, b) =>
                (b.startTime ?? b.date).compareTo(a.startTime ?? a.date)))) ...[
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
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md, vertical: AppSpacing.sm),
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
                width: nap ? 32 : 36,
                height: nap ? 32 : 36,
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
                      style: nap
                          ? AppText.label.copyWith(
                              color: AppColors.ink, fontWeight: FontWeight.w700)
                          : AppText.title),
                  const SizedBox(height: 2),
                  if (start != null && end != null)
                    Text(
                      '${_SleepTabState.clock(start)} – ${_SleepTabState.clock(end)}',
                      style:
                          AppText.caption.copyWith(color: AppColors.inkMuted),
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

// ===========================================================================
// Sleep sounds (phone-microphone snoring) — opt-in, on-device
// ===========================================================================

class _SnoringSection extends StatelessWidget {
  const _SnoringSection();

  void _open(BuildContext context) => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const SnoreTrackingScreen()),
      );

  @override
  Widget build(BuildContext context) {
    final audio = context.watch<SleepAudioController>();
    if (audio.isListening) {
      return _SnoreListeningCard(onTap: () => _open(context));
    }
    final s = audio.lastSession;
    if (s == null) {
      return _SnoreOptIn(onStart: () => _open(context));
    }
    return _SnoreResult(session: s, onTrackAgain: () => _open(context));
  }
}

class _SnoreOptIn extends StatelessWidget {
  final VoidCallback onStart;
  const _SnoreOptIn({required this.onStart});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: onStart,
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(Icons.mic_rounded, color: AppColors.primary, size: 22),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Track snoring with your phone', style: AppText.title),
                const SizedBox(height: 2),
                Text('On-device and private — no audio is saved.',
                    style: AppText.caption.copyWith(color: AppColors.inkMuted)),
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded, color: AppColors.inkFaint),
        ],
      ),
    );
  }
}

class _SnoreListeningCard extends StatelessWidget {
  final VoidCallback onTap;
  const _SnoreListeningCard({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: onTap,
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration:
                BoxDecoration(color: AppColors.danger, shape: BoxShape.circle),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text('Listening for snoring…', style: AppText.title),
          ),
          Text('View', style: AppText.label.copyWith(color: AppColors.primary)),
        ],
      ),
    );
  }
}

class _SnoreResult extends StatelessWidget {
  final SnoreSession session;
  final VoidCallback onTrackAgain;
  const _SnoreResult({required this.session, required this.onTrackAgain});

  @override
  Widget build(BuildContext context) {
    final sum = session.summary;
    final none = sum.eventCount == 0;
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
                  color: AppColors.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(11),
                ),
                child:
                    Icon(Icons.mic_rounded, color: AppColors.primary, size: 19),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Snoring', style: AppText.title),
                    Text('from phone microphone',
                        style: AppText.caption
                            .copyWith(color: AppColors.inkFaint)),
                  ],
                ),
              ),
              IconButton(
                onPressed: onTrackAgain,
                icon: Icon(Icons.refresh_rounded, color: AppColors.inkMuted),
                tooltip: 'Track again tonight',
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          if (none)
            Text('No snoring detected',
                style: AppText.sectionTitle.copyWith(color: AppColors.success))
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text('${sum.totalMinutes}', style: AppText.metric),
                const SizedBox(width: 4),
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text('min snoring', style: AppText.label),
                ),
                const Spacer(),
                Text(
                    '${sum.eventCount} episode${sum.eventCount == 1 ? '' : 's'}',
                    style: AppText.label.copyWith(color: AppColors.inkMuted)),
              ],
            ),
          const SizedBox(height: AppSpacing.md),
          SizedBox(
            height: 30,
            child: CustomPaint(
              size: Size.infinite,
              painter: _SnoreTimelinePainter(session),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Text(_SleepTabState.clock(session.start),
                  style: AppText.caption.copyWith(color: AppColors.inkFaint)),
              const Spacer(),
              Text(_SleepTabState.clock(session.end),
                  style: AppText.caption.copyWith(color: AppColors.inkFaint)),
            ],
          ),
        ],
      ),
    );
  }
}

class _SnoreTimelinePainter extends CustomPainter {
  final SnoreSession session;
  _SnoreTimelinePainter(this.session);

  @override
  void paint(Canvas canvas, Size size) {
    final track = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, size.height / 2 - 4, size.width, 8),
      const Radius.circular(4),
    );
    canvas.drawRRect(track, Paint()..color = AppColors.surfaceAlt);

    final spanMs = session.end.difference(session.start).inMilliseconds;
    if (spanMs <= 0) return;
    for (final e in session.events) {
      final x0 = (e.start.difference(session.start).inMilliseconds / spanMs) *
          size.width;
      final w = (e.durationSeconds * 1000 / spanMs) * size.width;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x0.clamp(0, size.width), size.height / 2 - 6,
            w.clamp(3.0, size.width), 12),
        const Radius.circular(3),
      );
      canvas.drawRRect(
        rect,
        Paint()
          ..color = AppColors.primary.withValues(alpha: 0.4 + e.peak * 0.6),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SnoreTimelinePainter old) =>
      old.session != session;
}

/// Sleep Regularity Index — how consistently the user sleeps at the same times.
///
/// Shown with the population median beside it, because a bare "70" means
/// nothing on its own. Gated: below the 5-day minimum it says how many days are
/// still needed instead of showing a number.
class _RegularityCard extends StatelessWidget {
  const _RegularityCard({required this.result});

  final SleepRegularityResult? result;

  @override
  Widget build(BuildContext context) {
    final r = result;
    if (r == null || !r.hasValue) {
      return AppCard(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Text(
            r?.explanation ?? 'Sleep regularity needs a few days of data.',
            style: AppText.caption.copyWith(color: AppColors.inkMuted),
          ),
        ),
      );
    }
    final v = r.index!;
    // Position on the -100..100 scale, for the bar.
    final frac = ((v + 100) / 200).clamp(0.0, 1.0);
    return AppCard(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(v.toStringAsFixed(0), style: AppText.metric),
                const SizedBox(width: AppSpacing.sm),
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(r.label,
                      style: AppText.title.copyWith(color: AppColors.sleep)),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            RepaintBoundary(
              child: LayoutBuilder(
                builder: (context, c) => Stack(
                  children: [
                    Container(
                      height: 8,
                      decoration: BoxDecoration(
                        color: AppColors.surfaceAlt,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    // Population median marker.
                    Positioned(
                      left: c.maxWidth *
                          ((SleepRegularity.populationMedian + 100) / 200),
                      child: Container(
                          width: 2, height: 8, color: AppColors.inkFaint),
                    ),
                    Container(
                      height: 8,
                      width: c.maxWidth * frac,
                      decoration: BoxDecoration(
                        color: AppColors.sleep,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '${r.explanation} Based on ${r.comparedDays} days.',
              style: AppText.caption.copyWith(color: AppColors.inkMuted),
            ),
          ],
        ),
      ),
    );
  }
}
