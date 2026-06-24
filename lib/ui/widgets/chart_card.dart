import 'package:flutter/material.dart';
import 'app_card.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// A titled surface that frames a chart (fl_chart) or any custom body.
/// Header: title + optional subtitle on the left, optional [trailing] control
/// (e.g. a SegmentedToggle) on the right. The [child] sits in a fixed-[height]
/// box below.
class ChartCard extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget child;
  final double height;
  final EdgeInsetsGeometry padding;

  const ChartCard({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.trailing,
    this.height = 200,
    this.padding = const EdgeInsets.all(AppSpacing.lg),
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: AppText.title),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(subtitle!,
                          style: AppText.caption
                              .copyWith(color: AppColors.inkMuted)),
                    ],
                  ],
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          SizedBox(height: height, child: child),
        ],
      ),
    );
  }
}

/// A simple empty/placeholder body for charts with no data yet.
class ChartEmpty extends StatelessWidget {
  final String message;
  final IconData icon;
  const ChartEmpty({
    super.key,
    this.message = 'No data yet',
    this.icon = Icons.show_chart_rounded,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 32, color: AppColors.inkFaint),
          const SizedBox(height: AppSpacing.sm),
          Text(message,
              style: AppText.label.copyWith(color: AppColors.inkFaint)),
        ],
      ),
    );
  }
}
