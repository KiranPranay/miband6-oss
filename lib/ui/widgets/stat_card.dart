import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'app_card.dart';
import 'count_up_text.dart';

/// A compact metric tile: tinted icon, animated value + unit, quiet label.
class StatCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final num value;
  final int decimals;
  final String unit;
  final String label;
  final VoidCallback? onTap;

  const StatCard({
    super.key,
    required this.icon,
    required this.color,
    required this.value,
    required this.label,
    this.decimals = 0,
    this.unit = '',
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: CountUpText(value,
                    style: AppText.metricSm, decimals: decimals),
              ),
              if (unit.isNotEmpty) ...[
                const SizedBox(width: 3),
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(unit, style: AppText.unit),
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
