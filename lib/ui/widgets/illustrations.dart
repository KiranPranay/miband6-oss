import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Line illustrations, drawn rather than shipped as assets.
///
/// Each is a few strokes in the current palette, so they stay crisp at any
/// size and correct in both themes. They are here to give a screen a focal
/// point and some air — not to decorate. Every one encodes something real:
/// the arc is the actual span of the night or day, the trace is a pulse, the
/// trail is progress towards a goal.

/// A horizon with the sun or moon somewhere along its arc.
///
/// [progress] is 0 at the left horizon and 1 at the right. Pass the fraction
/// of the day (for a sun) or of the night (for a moon) that has elapsed, and
/// the body sits where it would in the sky.
class SkyArc extends StatelessWidget {
  final double progress;
  final bool night;
  final Color color;
  final double height;

  const SkyArc({
    super.key,
    required this.progress,
    this.night = false,
    Color? color,
    this.height = 84,
  }) : color = color ?? const Color(0xFF000000);

  @override
  Widget build(BuildContext context) {
    final c = color == const Color(0xFF000000)
        ? (night ? AppColors.sleep : AppColors.warning)
        : color;
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _SkyArcPainter(
          progress: progress.clamp(0.0, 1.0),
          night: night,
          body: c,
          line: AppColors.divider,
          faint: AppColors.inkFaint,
        ),
      ),
    );
  }
}

class _SkyArcPainter extends CustomPainter {
  final double progress;
  final bool night;
  final Color body, line, faint;
  const _SkyArcPainter(
      {required this.progress,
      required this.night,
      required this.body,
      required this.line,
      required this.faint});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final horizonY = h - 10;
    final r = Rect.fromLTRB(8, 14, w - 8, horizonY * 2 - 14);

    // Horizon.
    canvas.drawLine(
        Offset(0, horizonY), Offset(w, horizonY), Paint()..color = line..strokeWidth = 1);

    // The arc: dashed, light.
    final arcPaint = Paint()
      ..color = line
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final path = Path()..addArc(r, math.pi, math.pi);
    for (final m in path.computeMetrics()) {
      var d = 0.0;
      while (d < m.length) {
        canvas.drawPath(m.extractPath(d, d + 4), arcPaint);
        d += 9;
      }
    }

    // A few stars at night, none by day.
    if (night) {
      final star = Paint()..color = faint.withValues(alpha: 0.7);
      for (final (fx, fy, s) in [(0.12, 0.28, 1.4), (0.3, 0.12, 1.0), (0.7, 0.16, 1.2), (0.86, 0.34, 0.9)]) {
        canvas.drawCircle(Offset(w * fx, horizonY * fy), s, star);
      }
    }

    // The body on the arc.
    final ang = math.pi + math.pi * progress;
    final cx = r.center.dx + r.width / 2 * math.cos(ang);
    final cy = r.center.dy + r.height / 2 * math.sin(ang);
    final glow = Paint()..color = body.withValues(alpha: 0.18);
    canvas.drawCircle(Offset(cx, cy), 14, glow);
    if (night) {
      // Crescent: a disc with a second disc cut from it.
      final moon = Path()..addOval(Rect.fromCircle(center: Offset(cx, cy), radius: 8));
      final bite = Path()..addOval(Rect.fromCircle(center: Offset(cx + 4, cy - 2), radius: 7));
      canvas.drawPath(Path.combine(PathOperation.difference, moon, bite),
          Paint()..color = body);
    } else {
      canvas.drawCircle(Offset(cx, cy), 8, Paint()..color = body);
      final ray = Paint()..color = body..strokeWidth = 1.4..strokeCap = StrokeCap.round;
      for (var i = 0; i < 8; i++) {
        final a = i * math.pi / 4;
        canvas.drawLine(
            Offset(cx + 11 * math.cos(a), cy + 11 * math.sin(a)),
            Offset(cx + 14 * math.cos(a), cy + 14 * math.sin(a)),
            ray);
      }
    }
  }

  @override
  bool shouldRepaint(_SkyArcPainter o) =>
      o.progress != progress || o.night != night || o.body != body || o.line != line;
}

/// A single heartbeat trace, ECG-shaped. [bpm] sets how wide one beat is so
/// the line visibly quickens; null draws a flat line with one faint beat.
class PulseTrace extends StatelessWidget {
  final int? bpm;
  final double height;
  final Color? color;
  const PulseTrace({super.key, this.bpm, this.height = 56, this.color});

  @override
  Widget build(BuildContext context) => SizedBox(
        height: height,
        width: double.infinity,
        child: CustomPaint(
          painter: _PulsePainter(
              bpm: bpm, color: color ?? AppColors.heart, faint: AppColors.divider),
        ),
      );
}

class _PulsePainter extends CustomPainter {
  final int? bpm;
  final Color color, faint;
  const _PulsePainter({required this.bpm, required this.color, required this.faint});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height, mid = h / 2;
    final beat = ((bpm ?? 60).clamp(40, 180) - 40) / 140; // 0 slow .. 1 fast
    final period = w / (2.2 + beat * 2.8); // more beats per width when fast
    final p = Paint()
      ..color = bpm == null ? faint : color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    final path = Path()..moveTo(0, mid);
    var x = 0.0;
    while (x < w) {
      final s = period;
      path
        ..lineTo(x + s * 0.30, mid)
        ..lineTo(x + s * 0.36, mid - h * 0.10)
        ..lineTo(x + s * 0.42, mid + h * 0.06)
        ..lineTo(x + s * 0.48, mid - h * 0.42)
        ..lineTo(x + s * 0.54, mid + h * 0.30)
        ..lineTo(x + s * 0.60, mid)
        ..lineTo(x + s * 0.74, mid)
        ..quadraticBezierTo(x + s * 0.80, mid - h * 0.14, x + s * 0.86, mid)
        ..lineTo(x + s, mid);
      x += s;
    }
    canvas.drawPath(path, p);
  }

  @override
  bool shouldRepaint(_PulsePainter o) => o.bpm != bpm || o.color != color;
}

/// A dotted trail of footprints across the width, filled to [progress].
class StepTrail extends StatelessWidget {
  final double progress;
  final double height;
  const StepTrail({super.key, required this.progress, this.height = 44});

  @override
  Widget build(BuildContext context) => SizedBox(
        height: height,
        width: double.infinity,
        child: CustomPaint(
          painter: _TrailPainter(
              progress: progress.clamp(0.0, 1.0),
              done: AppColors.activity,
              todo: AppColors.divider),
        ),
      );
}

class _TrailPainter extends CustomPainter {
  final double progress;
  final Color done, todo;
  const _TrailPainter({required this.progress, required this.done, required this.todo});

  @override
  void paint(Canvas canvas, Size size) {
    const n = 14;
    final w = size.width, h = size.height;
    final step = w / n;
    for (var i = 0; i < n; i++) {
      final x = step * i + step / 2;
      final y = h / 2 + (i.isEven ? -h * 0.16 : h * 0.16);
      final filled = (i + 0.5) / n <= progress;
      final paint = Paint()..color = filled ? done : todo;
      // A footprint: a small oval plus a smaller toe oval, mirrored per foot.
      final flip = i.isEven ? 1.0 : -1.0;
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(-0.35 * flip);
      canvas.drawOval(Rect.fromCenter(center: Offset.zero, width: 6, height: 11), paint);
      canvas.drawOval(
          Rect.fromCenter(center: const Offset(0, -8.5), width: 5, height: 4), paint);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_TrailPainter o) => o.progress != progress || o.done != done;
}

/// Moon and stars for a sleep empty state.
class MoonAndStars extends StatelessWidget {
  final double size;
  const MoonAndStars({super.key, this.size = 72});

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size.square(size),
        painter: _MoonPainter(body: AppColors.sleep, faint: AppColors.inkFaint),
      );
}

class _MoonPainter extends CustomPainter {
  final Color body, faint;
  const _MoonPainter({required this.body, required this.faint});

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width * 0.28;
    final moon = Path()..addOval(Rect.fromCircle(center: c, radius: r));
    final bite = Path()..addOval(Rect.fromCircle(center: c + Offset(r * 0.55, -r * 0.25), radius: r * 0.9));
    canvas.drawPath(Path.combine(PathOperation.difference, moon, bite),
        Paint()..color = body.withValues(alpha: 0.9));
    final star = Paint()..color = faint;
    for (final (fx, fy, s) in [(0.16, 0.22, 1.6), (0.82, 0.18, 1.2), (0.78, 0.74, 1.4), (0.24, 0.8, 1.0)]) {
      canvas.drawCircle(Offset(size.width * fx, size.height * fy), s, star);
    }
  }

  @override
  bool shouldRepaint(_MoonPainter o) => o.body != body;
}
