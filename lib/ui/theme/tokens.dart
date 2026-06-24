import 'package:flutter/material.dart';

/// Central design tokens for the redesign. Widgets reference these — no hardcoded
/// colors / sizes scattered around. Light-first, professional, lively.

class AppColors {
  AppColors._();

  // Surfaces
  static const scaffold = Color(0xFFF4F6FB); // soft off-white (not pure #FFF)
  static const surface = Color(0xFFFFFFFF);
  static const surfaceAlt = Color(0xFFEDF0F7);
  static const divider = Color(0xFFE7EAF1);

  // Brand
  static const primary = Color(0xFF5468FF); // confident indigo-blue
  static const primarySoft = Color(0xFFE9ECFF);

  // Domain accents + their soft tints
  static const heart = Color(0xFFFF5A72);
  static const heartSoft = Color(0xFFFFE4E9);
  static const activity = Color(0xFF1FB877);
  static const activitySoft = Color(0xFFDBF6EB);
  static const sleep = Color(0xFF6366F1);
  static const sleepSoft = Color(0xFFE7E8FE);
  static const spo2 = Color(0xFF14B8A6);
  static const spo2Soft = Color(0xFFD4F4F0);
  static const calories = Color(0xFFFB8C3C);
  static const caloriesSoft = Color(0xFFFFEAD7);
  static const distance = Color(0xFF3B82F6);
  static const distanceSoft = Color(0xFFDDEAFE);

  // Sleep stages
  static const sleepDeep = Color(0xFF4338CA);
  static const sleepLight = Color(0xFF8B93F8);
  static const sleepRem = Color(0xFF22C9E0);
  static const sleepAwake = Color(0xFFF6B23E);

  // Text / ink
  static const ink = Color(0xFF161B2E);
  static const inkMuted = Color(0xFF707892);
  static const inkFaint = Color(0xFFA3AAC0);

  // States
  static const success = Color(0xFF1FB877);
  static const warning = Color(0xFFF59E0B);
  static const danger = Color(0xFFEF4444);

  static Color domainSoft(Color c) => Color.alphaBlend(c.withValues(alpha: 0.12), surface);
}

class AppSpacing {
  AppSpacing._();
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double xxxl = 32;
}

class AppRadii {
  AppRadii._();
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 20;
  static const double xl = 28;
  static const double pill = 999;

  static BorderRadius all(double r) => BorderRadius.circular(r);
}

class AppShadows {
  AppShadows._();
  static List<BoxShadow> get card => [
        BoxShadow(
          color: const Color(0xFF161B2E).withValues(alpha: 0.05),
          blurRadius: 18,
          offset: const Offset(0, 8),
        ),
        BoxShadow(
          color: const Color(0xFF161B2E).withValues(alpha: 0.025),
          blurRadius: 3,
          offset: const Offset(0, 1),
        ),
      ];

  static List<BoxShadow> glow(Color c) => [
        BoxShadow(color: c.withValues(alpha: 0.30), blurRadius: 22, spreadRadius: -4),
      ];
}

/// Motion tokens. Keep animations quick + purposeful; gate the non-essential ones
/// behind reduce-motion.
class AppMotion {
  AppMotion._();
  static const Duration fast = Duration(milliseconds: 180);
  static const Duration medium = Duration(milliseconds: 280);
  static const Duration slow = Duration(milliseconds: 440);

  static const Curve ease = Curves.easeOutCubic;
  static const Curve emphasized = Cubic(0.2, 0.0, 0.0, 1.0);

  /// True when the user prefers reduced motion — gate decorative animations.
  static bool reduced(BuildContext context) =>
      MediaQuery.maybeOf(context)?.disableAnimations ?? false;
}
