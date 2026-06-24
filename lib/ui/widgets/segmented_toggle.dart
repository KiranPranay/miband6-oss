import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// A compact pill segmented control (e.g. Today / Week). Animated thumb.
class SegmentedToggle extends StatelessWidget {
  final List<String> options;
  final int index;
  final ValueChanged<int> onChanged;
  final Color accent;

  const SegmentedToggle({
    super.key,
    required this.options,
    required this.index,
    required this.onChanged,
    this.accent = AppColors.primary,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(AppRadii.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < options.length; i++)
            GestureDetector(
              onTap: () => onChanged(i),
              child: AnimatedContainer(
                duration: AppMotion.fast,
                curve: AppMotion.ease,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
                decoration: BoxDecoration(
                  color: i == index ? AppColors.surface : Colors.transparent,
                  borderRadius: BorderRadius.circular(AppRadii.pill),
                  boxShadow: i == index ? AppShadows.card : null,
                ),
                child: Text(
                  options[i],
                  style: AppText.label.copyWith(
                    color: i == index ? accent : AppColors.inkMuted,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
