import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// A circular heart-rate display whose inner glow pulses in sync with the
/// current BPM (one beat = 60000/bpm ms). Shows the live value, or a calm
/// "measuring…" state when there's no reading yet. Reduce-motion → static.
class PulsingHeartRing extends StatefulWidget {
  final int? bpm;
  final double size;
  final bool measuring;

  const PulsingHeartRing({
    super.key,
    required this.bpm,
    this.size = 220,
    this.measuring = false,
  });

  @override
  State<PulsingHeartRing> createState() => _PulsingHeartRingState();
}

class _PulsingHeartRingState extends State<PulsingHeartRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: _beat())..repeat();
  }

  Duration _beat() {
    final bpm = (widget.bpm ?? 70).clamp(35, 200);
    return Duration(milliseconds: (60000 / bpm).round());
  }

  @override
  void didUpdateWidget(covariant PulsingHeartRing old) {
    super.didUpdateWidget(old);
    if (old.bpm != widget.bpm) {
      _c.duration = _beat();
      if (!_c.isAnimating) _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.reduced(context);
    final hasReading = widget.bpm != null && widget.bpm! > 0;
    final color = AppColors.heart;

    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          // Heart-beat envelope: quick thump then ease back.
          final t = _c.value;
          final beat = reduced
              ? 0.0
              : (math.exp(-12 * t) * math.sin(t * math.pi * 2) +
                      math.exp(-12 * (t - 0.18).clamp(0, 1)) * 0.4)
                  .clamp(0.0, 1.0);
          final glow = hasReading ? 0.25 + beat * 0.55 : 0.18;
          final scale = hasReading && !reduced ? 1 + beat * 0.05 : 1.0;

          return Stack(
            alignment: Alignment.center,
            children: [
              // Soft pulsing halo
              Container(
                width: widget.size * 0.86,
                height: widget.size * 0.86,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: color.withValues(alpha: glow * 0.5),
                      blurRadius: 40,
                      spreadRadius: 4 + beat * 10,
                    ),
                  ],
                ),
              ),
              // Ring frame
              CustomPaint(
                size: Size.square(widget.size),
                painter: _RingPainter(color: color, active: hasReading),
              ),
              // Center content
              Transform.scale(
                scale: scale,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.favorite_rounded,
                        color: color, size: widget.size * 0.13),
                    const SizedBox(height: 6),
                    if (hasReading)
                      Text('${widget.bpm}',
                          style: AppText.metricHero
                              .copyWith(fontSize: widget.size * 0.27))
                    else
                      Text('--',
                          style: AppText.metricHero.copyWith(
                              fontSize: widget.size * 0.27,
                              color: AppColors.inkFaint)),
                    Text(
                      hasReading
                          ? 'BPM'
                          : (widget.measuring ? 'measuring…' : 'no reading'),
                      style: AppText.label.copyWith(
                        letterSpacing: 2,
                        color: hasReading ? color : AppColors.inkFaint,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final Color color;
  final bool active;
  _RingPainter({required this.color, required this.active});

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2 - 8;

    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: 0.10);
    canvas.drawCircle(center, radius, track);

    if (active) {
      final sweep = math.pi * 1.6;
      final rect = Rect.fromCircle(center: center, radius: radius);
      final arc = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 12
        ..strokeCap = StrokeCap.round
        ..shader = SweepGradient(
          startAngle: -math.pi / 2,
          endAngle: -math.pi / 2 + sweep,
          colors: [color.withValues(alpha: 0.25), color],
        ).createShader(rect);
      canvas.drawArc(rect, -math.pi / 2, sweep, false, arc);
    }
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      old.active != active || old.color != color;
}
