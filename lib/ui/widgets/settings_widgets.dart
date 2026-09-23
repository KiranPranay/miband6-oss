import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// The one family of list widgets used by Settings, Profile and every screen
/// that offers choices. One grammar everywhere: a tracked-out group label, a
/// single surface card, hairline-divided rows inside it. Profile used to draw
/// each feature as its own rounded card while Settings grouped rows in one —
/// two dialects for the same sentence.

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.title, {super.key});
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, AppSpacing.xxl, 4, AppSpacing.sm),
        child: Text(title.toUpperCase(), style: AppText.overline),
      );
}

class GroupCard extends StatelessWidget {
  const GroupCard({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadii.lg),
          boxShadow: AppShadows.card,
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) Divider(height: 1, color: AppColors.divider),
              children[i],
            ],
          ],
        ),
      );
}

/// A row that opens another screen or runs an action.
class NavTile extends StatelessWidget {
  const NavTile({
    super.key,
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.iconColor,
    this.titleColor,
    this.subtitleColor,
    this.trailingText,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Color? iconColor;
  final Color? titleColor;
  final Color? subtitleColor;
  final String? trailingText;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
        leading: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: (iconColor ?? AppColors.inkMuted).withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: iconColor ?? AppColors.inkMuted, size: 19),
        ),
        title: Text(title,
            style: AppText.body.copyWith(color: titleColor ?? AppColors.ink)),
        subtitle: subtitle == null
            ? null
            : Text(subtitle!,
                style: AppText.caption
                    .copyWith(color: subtitleColor ?? AppColors.inkMuted)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (trailingText != null)
              Text(trailingText!,
                  style: AppText.label.copyWith(color: AppColors.inkMuted)),
            Icon(Icons.chevron_right, color: AppColors.inkFaint),
          ],
        ),
        onTap: onTap,
      );
}

class SwitchTile extends StatelessWidget {
  const SwitchTile({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final Future<bool> Function(bool) onChanged;

  @override
  Widget build(BuildContext context) => SwitchListTile(
        value: value,
        title: Text(title, style: AppText.body),
        subtitle: subtitle == null
            ? null
            : Text(subtitle!,
                style: AppText.caption.copyWith(color: AppColors.inkMuted)),
        onChanged: (v) => onChanged(v),
      );
}
