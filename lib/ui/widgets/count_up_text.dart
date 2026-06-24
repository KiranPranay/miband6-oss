import 'package:flutter/material.dart';
import '../theme/tokens.dart';

/// Animates a number counting up to [value] when it appears / changes. Respects
/// reduce-motion (jumps straight to the value).
class CountUpText extends StatelessWidget {
  final num value;
  final TextStyle style;
  final int decimals;
  final String suffix;
  final String prefix;

  const CountUpText(
    this.value, {
    super.key,
    required this.style,
    this.decimals = 0,
    this.suffix = '',
    this.prefix = '',
  });

  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.reduced(context);
    if (reduced) {
      return Text('$prefix${value.toStringAsFixed(decimals)}$suffix',
          style: style);
    }
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: value.toDouble()),
      duration: AppMotion.slow,
      curve: AppMotion.ease,
      builder: (context, v, _) => Text(
        '$prefix${v.toStringAsFixed(decimals)}$suffix',
        style: style,
      ),
    );
  }
}
