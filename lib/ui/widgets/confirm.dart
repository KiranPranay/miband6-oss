import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// Asks before an action that is hard to undo or that reaches the band.
///
/// Returns true only when the person tapped the confirming button. The
/// destructive variant colours that button red so the eye lands on what it
/// is about to do; the wording is the caller's, in plain language, saying
/// what will happen rather than asking "are you sure".
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool destructive = false,
  IconData? icon,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.lg)),
      icon: icon == null
          ? null
          : Icon(icon, color: destructive ? AppColors.danger : AppColors.primary),
      title: Text(title, style: AppText.sectionTitle, textAlign: TextAlign.center),
      content: Text(message,
          style: AppText.body.copyWith(color: AppColors.inkMuted),
          textAlign: TextAlign.center),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text('Cancel', style: AppText.label.copyWith(color: AppColors.inkMuted)),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: FilledButton.styleFrom(
            backgroundColor: destructive ? AppColors.danger : AppColors.primary,
            foregroundColor: AppColors.isDark && !destructive
                ? const Color(0xFF10121A)
                : Colors.white,
          ),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result == true;
}
