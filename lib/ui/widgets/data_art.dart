import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/activity_sample.dart';
import '../../core/heart_analysis.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// Illustrations that *are* the data.
///
/// The sky arc and the pulse trace set a mood; these carry the numbers. Each
/// is a single canvas that a reader can take in at a glance and then read
/// closely, the way a good chart works: the shape says "how was the day", the
/// details say exactly how. All are drawn in the palette so they hold in both
/// themes, and none invents a value — a missing hour is an absent bar, not a
/// zero.

// ───────────────────────────────────────────────────────────────────────────
// Today — the day as a dial
// ───────────────────────────────────────────────────────────────────────────

/// A 24-hour dial: midnight at the top, clockwise. Three layers, outermost
/// first — hourly steps as radial bars, the night's sleep as an arc, and the
/// score in the centre. A marker on the rim sits at the current time.
class DayDial extends StatelessWidget {
  final List<HourlySteps> hourly;
  final DateTime? sleepStart;
  final DateTime? sleepEnd;
  final DateTime now;
  final Widget child;
  final double size;

  const DayDial({
    super.key,
    required this.hourly,
    required this.now,
    required this.child,
    this.sleepStart,
    this.sleepEnd,
    this.size = 268,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: Size.square(size),
            painter: _DayDialPainter(
              hourly: hourly,
              sleepStart: sleepStart,
              sleepEnd: sleepEnd,
              now: now,
              steps: AppColors.activity,
              sleep: AppColors.sleep,
              track: AppColors.divider,
              faint: AppColors.inkFaint,
              labelStyle: AppText.caption.copyWith(color: AppColors.inkFaint),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

class _DayDialPainter extends CustomPainter {
  final List<HourlySteps> hourly;
  final DateTime? sleepStart, sleepEnd;
  final DateTime now;
  final Color steps, sleep, track, faint;
  final TextStyle labelStyle;

  const _DayDialPainter({
    required this.hourly,
    required this.sleepStart,
    required this.sleepEnd,
    required this.now,
    required this.steps,
    required this.sleep,
    required this.track,
    required this.faint,
    required this.labelStyle,
  });

  double _angle(DateTime t) =>
      -math.pi / 2 + 2 * math.pi * (t.hour * 60 + t.minute) / 1440;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final rOuter = size.width / 2 - 14; // rim for labels + now marker
    final rBarBase = rOuter - 26; // steps bars grow from here outward
    final rSleep = rBarBase - 14; // sleep arc
    final byHour = {for (final h in hourly) h.hour: h.steps};
    final maxSteps = hourly.fold<int>(0, (m, h) => math.max(m, h.steps));

    // Guide ring at the bar base.
    canvas.drawCircle(
        c, rBarBase, Paint()..color = track..style = PaintingStyle.stroke..strokeWidth = 1);

    // Hourly step bars. A missing hour is simply absent.
    if (maxSteps > 0) {
      final p = Paint()
        ..color = steps
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round;
      for (var h = 0; h < 24; h++) {
        final s = byHour[h];
        if (s == null || s == 0) continue;
        final len = 4 + 20 * (s / maxSteps);
        final a = -math.pi / 2 + 2 * math.pi * (h + 0.5) / 24;
        final from = c + Offset(math.cos(a), math.sin(a)) * rBarBase;
        final to = c + Offset(math.cos(a), math.sin(a)) * (rBarBase + len);
        canvas.drawLine(from, to, p..color = steps.withValues(alpha: 0.55 + 0.45 * (s / maxSteps)));
      }
    }

    // The night, as an arc.
    if (sleepStart != null && sleepEnd != null) {
      final a0 = _angle(sleepStart!);
      var sweep = sleepEnd!.difference(sleepStart!).inMinutes / 1440 * 2 * math.pi;
      if (sweep <= 0) sweep += 2 * math.pi;
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: rSleep),
        a0,
        sweep,
        false,
        Paint()
          ..color = sleep
          ..style = PaintingStyle.stroke
          ..strokeWidth = 7
          ..strokeCap = StrokeCap.round,
      );
    }

    // Quarter labels on the rim.
    for (final (label, h) in [('12a', 0), ('6a', 6), ('12p', 12), ('6p', 18)]) {
      final a = -math.pi / 2 + 2 * math.pi * h / 24;
      final pos = c + Offset(math.cos(a), math.sin(a)) * (rOuter + 2);
      final tp = TextPainter(
          text: TextSpan(text: label, style: labelStyle),
          textDirection: TextDirection.ltr)
        ..layout();
      tp.paint(canvas, pos - Offset(tp.width / 2, tp.height / 2));
    }

    // Now.
    final an = _angle(now);
    final pn = c + Offset(math.cos(an), math.sin(an)) * (rBarBase - 1);
    canvas.drawCircle(pn, 4.5, Paint()..color = faint);
    canvas.drawCircle(pn, 2.5, Paint()..color = track);
  }

  @override
  bool shouldRepaint(_DayDialPainter o) =>
      o.hourly != hourly ||
      o.sleepStart != sleepStart ||
      o.sleepEnd != sleepEnd ||
      o.now.minute != now.minute ||
      o.steps != steps;
}

// ───────────────────────────────────────────────────────────────────────────
// Sleep — the night's arc, segmented by stage
// ───────────────────────────────────────────────────────────────────────────

/// The sky arc, but the stroke *is* the hypnogram: from bedtime at the left
/// horizon to waking at the right, each interval drawn in its stage colour —
/// deep as the thickest, awake as the thinnest. The moon sits at the midpoint.
class NightArc extends StatelessWidget {
  final SleepDay day;
  final double height;
  const NightArc({super.key, required this.day, this.height = 104});

  @override
  Widget build(BuildContext context) => SizedBox(
        height: height,
        width: double.infinity,
        child: CustomPaint(
          painter: _NightArcPainter(
            day: day,
            deep: AppColors.sleepDeep,
            light: AppColors.sleepLight,
            awake: AppColors.sleepAwake,
            moon: AppColors.sleep,
            line: AppColors.divider,
            faint: AppColors.inkFaint,
          ),
        ),
      );
}

class _NightArcPainter extends CustomPainter {
  final SleepDay day;
  final Color deep, light, awake, moon, line, faint;
  const _NightArcPainter({
    required this.day,
    required this.deep,
    required this.light,
    required this.awake,
    required this.moon,
    required this.line,
    required this.faint,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final horizonY = h - 12;
    final r = Rect.fromLTRB(10, 16, w - 10, horizonY * 2 - 16);
    canvas.drawLine(Offset(0, horizonY), Offset(w, horizonY),
        Paint()..color = line..strokeWidth = 1);

    final start = day.startTime, end = day.endTime;
    if (start == null || end == null || !end.isAfter(start)) return;
    final total = end.difference(start).inSeconds.toDouble();

    // Faint full arc underneath, so gaps in the data read as gaps.
    canvas.drawArc(r, math.pi, math.pi, false,
        Paint()..color = line..style = PaintingStyle.stroke..strokeWidth = 1);

    for (final iv in day.intervals) {
      final a0 = math.pi + math.pi * (iv.startTime.difference(start).inSeconds / total).clamp(0.0, 1.0);
      final a1 = math.pi + math.pi * (iv.endTime.difference(start).inSeconds / total).clamp(0.0, 1.0);
      if (a1 <= a0) continue;
      final (color, width) = switch (iv.stage) {
        SleepStage.deep => (deep, 9.0),
        SleepStage.awake => (awake, 2.5),
        _ => (light, 6.0),
      };
      canvas.drawArc(r, a0, a1 - a0, false,
          Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = width..strokeCap = StrokeCap.butt);
    }

    // Stars, sparse.
    final star = Paint()..color = faint.withValues(alpha: 0.6);
    for (final (fx, fy, s) in [(0.14, 0.30, 1.3), (0.32, 0.14, 1.0), (0.68, 0.16, 1.2), (0.85, 0.36, 0.9)]) {
      canvas.drawCircle(Offset(w * fx, horizonY * fy), s, star);
    }

    // Moon at the top of the arc.
    final cx = r.center.dx, cy = r.top;
    canvas.drawCircle(Offset(cx, cy - 2), 15, Paint()..color = moon.withValues(alpha: 0.16));
    final disc = Path()..addOval(Rect.fromCircle(center: Offset(cx, cy - 2), radius: 8));
    final bite = Path()..addOval(Rect.fromCircle(center: Offset(cx + 4, cy - 4), radius: 7));
    canvas.drawPath(Path.combine(PathOperation.difference, disc, bite), Paint()..color = moon);
  }

  @override
  bool shouldRepaint(_NightArcPainter o) => o.day != day || o.deep != deep;
}

// ───────────────────────────────────────────────────────────────────────────
// Heart — today's range on the zone scale
// ───────────────────────────────────────────────────────────────────────────

/// A horizontal scale with the heart-rate zones as bands, today's lowest to
/// highest as a filled bar across them, resting as a hollow marker and the
/// current reading as a dot. Reads as "where did today sit, and where am I
/// now" without a single number — and then the numbers are right there.
class HeartRange extends StatelessWidget {
  final int? min, max, resting, current;
  final List<HrZone> zones;
  const HeartRange({
    super.key,
    required this.min,
    required this.max,
    required this.resting,
    required this.current,
    required this.zones,
  });

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 64,
        width: double.infinity,
        child: CustomPaint(
          painter: _HeartRangePainter(
            min: min,
            max: max,
            resting: resting,
            current: current,
            zones: zones,
            bar: AppColors.heart,
            restingColor: AppColors.sleep,
            ink: AppColors.ink,
            faint: AppColors.inkFaint,
            surface: AppColors.surface,
            zoneColor: (label) => switch (label) {
              'Resting' => AppColors.sleep,
              'Elevated' => AppColors.warning,
              _ => AppColors.success,
            },
            labelStyle: AppText.caption.copyWith(color: AppColors.inkFaint),
            figureStyle: AppText.label.copyWith(color: AppColors.ink),
          ),
        ),
      );
}

class _HeartRangePainter extends CustomPainter {
  final int? min, max, resting, current;
  final List<HrZone> zones;
  final Color bar, restingColor, ink, faint, surface;
  final Color Function(String) zoneColor;
  final TextStyle labelStyle, figureStyle;
  const _HeartRangePainter({
    required this.min,
    required this.max,
    required this.resting,
    required this.current,
    required this.zones,
    required this.bar,
    required this.restingColor,
    required this.ink,
    required this.faint,
    required this.surface,
    required this.zoneColor,
    required this.labelStyle,
    required this.figureStyle,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final lo = math.min(40, (min ?? 60) - 10).toDouble();
    final hi = math.max(130, (max ?? 100) + 10).toDouble();
    double x(num v) => 12 + (w - 24) * ((v - lo) / (hi - lo)).clamp(0.0, 1.0);
    const y = 30.0;

    // Zone bands.
    for (final z in zones) {
      final l = x(z.low), r = x(z.high.clamp(0, 400));
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTRB(l, y - 6, r, y + 6), const Radius.circular(6)),
        Paint()..color = zoneColor(z.label).withValues(alpha: 0.16),
      );
      final tp = TextPainter(
          text: TextSpan(text: z.label, style: labelStyle), textDirection: TextDirection.ltr)
        ..layout();
      if (r - l > tp.width + 8) tp.paint(canvas, Offset((l + r) / 2 - tp.width / 2, y + 12));
    }

    if (min != null && max != null) {
      // Today's range.
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTRB(x(min!), y - 4, math.max(x(max!), x(min!) + 6), y + 4),
            const Radius.circular(4)),
        Paint()..color = bar.withValues(alpha: 0.85),
      );
      final tMin = TextPainter(
          text: TextSpan(text: '$min', style: figureStyle), textDirection: TextDirection.ltr)
        ..layout();
      final tMax = TextPainter(
          text: TextSpan(text: '$max', style: figureStyle), textDirection: TextDirection.ltr)
        ..layout();
      tMin.paint(canvas, Offset(x(min!) - tMin.width / 2, y - 26));
      tMax.paint(canvas, Offset(x(max!) - tMax.width / 2, y - 26));
    }
    if (resting != null) {
      canvas.drawCircle(Offset(x(resting!), y), 6, Paint()..color = surface);
      canvas.drawCircle(Offset(x(resting!), y), 6,
          Paint()..color = restingColor..style = PaintingStyle.stroke..strokeWidth = 2);
    }
    if (current != null && current! > 0) {
      canvas.drawCircle(Offset(x(current!), y), 5, Paint()..color = bar);
      canvas.drawCircle(Offset(x(current!), y), 5,
          Paint()..color = surface..style = PaintingStyle.stroke..strokeWidth = 1.5);
    }
  }

  @override
  bool shouldRepaint(_HeartRangePainter o) =>
      o.min != min || o.max != max || o.resting != resting || o.current != current;
}

// ───────────────────────────────────────────────────────────────────────────
// Activity — the day as a clock of steps
// ───────────────────────────────────────────────────────────────────────────

/// Goal progress as the outer ring; inside it, 24 spokes — one per hour,
/// length proportional to steps — so the shape of the day (a morning walk, a
/// dead afternoon, an evening run) is the first thing you see. Count in the
/// centre.
class ActivityClock extends StatelessWidget {
  final List<HourlySteps> hourly;
  final double progress;
  final Widget child;
  final double size;
  const ActivityClock({
    super.key,
    required this.hourly,
    required this.progress,
    required this.child,
    this.size = 176,
  });

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            CustomPaint(
              size: Size.square(size),
              painter: _ActivityClockPainter(
                hourly: hourly,
                progress: progress.clamp(0.0, 1.0),
                color: AppColors.activity,
                track: AppColors.divider,
              ),
            ),
            child,
          ],
        ),
      );
}

class _ActivityClockPainter extends CustomPainter {
  final List<HourlySteps> hourly;
  final double progress;
  final Color color, track;
  const _ActivityClockPainter(
      {required this.hourly, required this.progress, required this.color, required this.track});

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final rRing = size.width / 2 - 7;
    const stroke = 10.0;

    // Goal ring.
    canvas.drawCircle(c, rRing,
        Paint()..style = PaintingStyle.stroke..strokeWidth = stroke..color = track);
    if (progress > 0) {
      final rect = Rect.fromCircle(center: c, radius: rRing);
      final sweep = 2 * math.pi * progress;
      canvas.drawArc(
        rect,
        -math.pi / 2,
        sweep,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.round
          ..shader = SweepGradient(
            startAngle: -math.pi / 2,
            endAngle: -math.pi / 2 + sweep,
            colors: [color.withValues(alpha: 0.45), color],
          ).createShader(rect),
      );
    }

    // Spokes.
    final byHour = {for (final h in hourly) h.hour: h.steps};
    final maxSteps = hourly.fold<int>(0, (m, h) => math.max(m, h.steps));
    if (maxSteps == 0) return;
    final rIn = rRing - 20;
    final rSpan = rIn - 34; // leave the centre for the number
    final p = Paint()..strokeWidth = 3.5..strokeCap = StrokeCap.round;
    for (var h = 0; h < 24; h++) {
      final s = byHour[h];
      if (s == null || s == 0) continue;
      final f = s / maxSteps;
      final a = -math.pi / 2 + 2 * math.pi * (h + 0.5) / 24;
      final from = c + Offset(math.cos(a), math.sin(a)) * (rIn - rSpan * f);
      final to = c + Offset(math.cos(a), math.sin(a)) * rIn;
      canvas.drawLine(from, to, p..color = color.withValues(alpha: 0.45 + 0.55 * f));
    }
  }

  @override
  bool shouldRepaint(_ActivityClockPainter o) =>
      o.hourly != hourly || o.progress != progress || o.color != color;
}
