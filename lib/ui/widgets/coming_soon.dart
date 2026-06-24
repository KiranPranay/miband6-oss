import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// A deliberate "coming soon" preview — animated gradient orb, title, badge and
/// a one-line description. Used for Stress and AI Analysis.
class ComingSoonScreen extends StatelessWidget {
  final String title;
  final String description;
  final IconData icon;
  final List<Color> gradient;
  final bool showAppBar;

  const ComingSoonScreen({
    super.key,
    required this.title,
    required this.description,
    required this.icon,
    required this.gradient,
    this.showAppBar = true,
  });

  @override
  Widget build(BuildContext context) {
    final body = Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _GradientOrb(icon: icon, colors: gradient),
            const SizedBox(height: AppSpacing.xxl),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: gradient.first.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(AppRadii.pill),
              ),
              child: Text('COMING SOON',
                  style: AppText.caption.copyWith(
                      color: gradient.first,
                      letterSpacing: 1.4,
                      fontWeight: FontWeight.w800)),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(title, style: AppText.h1, textAlign: TextAlign.center),
            const SizedBox(height: AppSpacing.sm),
            Text(description,
                style: AppText.body.copyWith(color: AppColors.inkMuted),
                textAlign: TextAlign.center),
          ],
        ),
      ),
    );

    if (!showAppBar) return body;
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: body,
    );
  }
}

class _GradientOrb extends StatefulWidget {
  final IconData icon;
  final List<Color> colors;
  const _GradientOrb({required this.icon, required this.colors});

  @override
  State<_GradientOrb> createState() => _GradientOrbState();
}

class _GradientOrbState extends State<_GradientOrb>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 6))
        ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.reduced(context);
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final a = reduced ? 0.0 : _c.value * 2 * math.pi;
        return Container(
          width: 132,
          height: 132,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: SweepGradient(
              transform: GradientRotation(a),
              colors: [...widget.colors, widget.colors.first],
            ),
            boxShadow: [
              BoxShadow(
                color: widget.colors.first.withValues(alpha: 0.4),
                blurRadius: 36,
                spreadRadius: -2,
              ),
            ],
          ),
          child: Center(
            child: Container(
              width: 108,
              height: 108,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.surface,
              ),
              child: Icon(widget.icon, size: 46, color: widget.colors.first),
            ),
          ),
        );
      },
    );
  }
}
