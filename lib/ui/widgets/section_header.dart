import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// "Section title  ·············  optional action" row.
///
/// Two things here are deliberate rather than cosmetic.
///
/// *Weight*: the title uses [AppText.sectionTitle], one step below the screen
/// title, so a screen has a single loudest element instead of four or five
/// competing ones.
///
/// *Spacing*: the padding is asymmetric — a wide gap above, a narrow one below.
/// It used to be the other way round (8 above, 12 below), which by the Gestalt
/// law of proximity grouped each header with the card *before* it rather than
/// the one it labels. Owning the leading gap here also means callers no longer
/// need a `SizedBox` before every header, so the rhythm can't drift per screen.
class SectionHeader extends StatelessWidget {
  final String title;
  final Widget? trailing;

  /// Set false when the header is the first thing on a screen and the leading
  /// gap would just push everything down.
  final bool leadingGap;

  const SectionHeader(this.title, {super.key, this.trailing, this.leadingGap = true});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(AppSpacing.xs,
          leadingGap ? AppSpacing.section : 0, AppSpacing.xs, AppSpacing.lg),
      child: Row(
        children: [
          Expanded(child: Text(title, style: AppText.sectionTitle)),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// A small rounded pill (status / labels).
class Pill extends StatelessWidget {
  final String text;
  final Color color;
  final IconData? icon;
  const Pill(this.text, {super.key, required this.color, this.icon});

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
          if (icon != null) ...[
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 5),
          ],
          Text(text,
              style: AppText.caption.copyWith(
                  color: color, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}
