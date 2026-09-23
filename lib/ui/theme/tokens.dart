import 'package:flutter/material.dart';

/// Central design tokens for the redesign. Widgets reference these — no hardcoded
/// colors / sizes scattered around. Light-first, professional, lively.

/// One complete colour set. Two instances exist — light and dark — and
/// [AppColors] delegates to whichever is active.
///
/// Domain accents keep the *same hue* across both palettes so a metric is
/// recognisable by colour alone (HR warm, sleep indigo, stress teal); only their
/// lightness is adjusted, because a mid-tone that reads well on white is too
/// dark on near-black.
@immutable
class AppPalette {
  const AppPalette({
    required this.brightness,
    required this.scaffold,
    required this.surface,
    required this.surfaceAlt,
    required this.divider,
    required this.primary,
    required this.primarySoft,
    required this.heart,
    required this.heartSoft,
    required this.activity,
    required this.activitySoft,
    required this.sleep,
    required this.sleepSoft,
    required this.spo2,
    required this.spo2Soft,
    required this.stress,
    required this.stressSoft,
    required this.calories,
    required this.caloriesSoft,
    required this.distance,
    required this.distanceSoft,
    required this.sleepDeep,
    required this.sleepLight,
    required this.sleepRem,
    required this.sleepAwake,
    required this.ink,
    required this.inkMuted,
    required this.inkFaint,
    required this.success,
    required this.warning,
    required this.danger,
  });

  final Brightness brightness;
  final Color scaffold, surface, surfaceAlt, divider;
  final Color primary, primarySoft;
  final Color heart, heartSoft, activity, activitySoft;
  final Color sleep, sleepSoft, spo2, spo2Soft, stress, stressSoft;
  final Color calories, caloriesSoft, distance, distanceSoft;
  final Color sleepDeep, sleepLight, sleepRem, sleepAwake;
  final Color ink, inkMuted, inkFaint;
  final Color success, warning, danger;

  /// Light palette.
  ///
  /// Several accents were darkened from their original values so each clears
  /// WCAG 4.5:1 (text) / 3:1 (non-text) against `surface` — `test/theme_contrast_test.dart`
  /// enforces this. Hue is preserved, so the domain colour coding is unchanged.
  static const light = AppPalette(
    brightness: Brightness.light,
    scaffold: Color(0xFFF4F6FB), // soft off-white (not pure #FFF)
    surface: Color(0xFFFFFFFF),
    surfaceAlt: Color(0xFFEDF0F7),
    divider: Color(0xFFE7EAF1),
    primary: Color(0xFF5468FF), // confident indigo-blue
    primarySoft: Color(0xFFE9ECFF),
    heart: Color(0xFFFF5A72),
    heartSoft: Color(0xFFFFE4E9),
    activity: Color(0xFF1DA96E),
    activitySoft: Color(0xFFDBF6EB),
    sleep: Color(0xFF6366F1),
    sleepSoft: Color(0xFFE7E8FE),
    spo2: Color(0xFF12A796),
    spo2Soft: Color(0xFFD4F4F0),
    stress: Color(0xFF0E9488),
    stressSoft: Color(0xFFD3F0ED),
    calories: Color(0xFFF66A05),
    caloriesSoft: Color(0xFFFFEAD7),
    distance: Color(0xFF3B82F6),
    distanceSoft: Color(0xFFDDEAFE),
    sleepDeep: Color(0xFF4338CA),
    sleepLight: Color(0xFF8B93F8),
    sleepRem: Color(0xFF1CB3C8),
    sleepAwake: Color(0xFFE2920B),
    ink: Color(0xFF161B2E),
    inkMuted: Color(0xFF6E7691),
    inkFaint: Color(0xFF8C94B0),
    success: Color(0xFF1DA96E),
    warning: Color(0xFFCE8508),
    danger: Color(0xFFEF4444),
  );

  /// Dark palette.
  ///
  /// Surfaces are near-black rather than pure black (pure black makes the
  /// elevation shadows invisible and is harsher on OLED at night, which is
  /// exactly when this app is read). Accents are lifted so each keeps ≥4.5:1
  /// contrast against `surface`; the "soft" tints become dark, low-saturation
  /// fills instead of pale washes.
  static const dark = AppPalette(
    brightness: Brightness.dark,
    scaffold: Color(0xFF0E1017),
    surface: Color(0xFF171A23),
    surfaceAlt: Color(0xFF1F2330),
    divider: Color(0xFF2A2F3D),
    primary: Color(0xFF8B9BFF),
    primarySoft: Color(0xFF232842),
    heart: Color(0xFFFF8095),
    heartSoft: Color(0xFF3A222A),
    activity: Color(0xFF3ED99A),
    activitySoft: Color(0xFF163228),
    sleep: Color(0xFF979CFF),
    sleepSoft: Color(0xFF23253F),
    spo2: Color(0xFF3FD6C4),
    spo2Soft: Color(0xFF14312F),
    stress: Color(0xFF33C2B4),
    stressSoft: Color(0xFF12302E),
    calories: Color(0xFFFFA766),
    caloriesSoft: Color(0xFF3A2A1C),
    distance: Color(0xFF6FA8FF),
    distanceSoft: Color(0xFF1B2740),
    sleepDeep: Color(0xFF7B7BEA),
    sleepLight: Color(0xFFA9AFFB),
    sleepRem: Color(0xFF56D8EA),
    sleepAwake: Color(0xFFFFC670),
    ink: Color(0xFFF2F4FA),
    inkMuted: Color(0xFFA6AEC4),
    inkFaint: Color(0xFF737B92),
    success: Color(0xFF3ED99A),
    warning: Color(0xFFFFC24D),
    danger: Color(0xFFFF6B6B),
  );
}

/// Design tokens, resolved against the active [AppPalette].
///
/// These are getters rather than constants so the whole app can switch palette
/// without every call site taking a `BuildContext`. [AppThemeController] sets
/// [palette] before the first frame and again whenever the platform brightness
/// or the user's preference changes.
class AppColors {
  AppColors._();

  static AppPalette _palette = AppPalette.light;

  static AppPalette get palette => _palette;

  /// Returns true when the palette actually changed (so callers can decide
  /// whether a rebuild is needed).
  static bool setPalette(AppPalette p) {
    if (identical(_palette, p)) return false;
    _palette = p;
    return true;
  }

  static bool get isDark => _palette.brightness == Brightness.dark;

  static Color get scaffold => _palette.scaffold;
  static Color get surface => _palette.surface;
  static Color get surfaceAlt => _palette.surfaceAlt;
  static Color get divider => _palette.divider;

  static Color get primary => _palette.primary;
  static Color get primarySoft => _palette.primarySoft;

  static Color get heart => _palette.heart;
  static Color get heartSoft => _palette.heartSoft;
  static Color get activity => _palette.activity;
  static Color get activitySoft => _palette.activitySoft;
  static Color get sleep => _palette.sleep;
  static Color get sleepSoft => _palette.sleepSoft;
  static Color get spo2 => _palette.spo2;
  static Color get spo2Soft => _palette.spo2Soft;
  static Color get stress => _palette.stress;
  static Color get stressSoft => _palette.stressSoft;
  static Color get calories => _palette.calories;
  static Color get caloriesSoft => _palette.caloriesSoft;
  static Color get distance => _palette.distance;
  static Color get distanceSoft => _palette.distanceSoft;

  static Color get sleepDeep => _palette.sleepDeep;
  static Color get sleepLight => _palette.sleepLight;
  static Color get sleepRem => _palette.sleepRem;
  static Color get sleepAwake => _palette.sleepAwake;

  static Color get ink => _palette.ink;
  static Color get inkMuted => _palette.inkMuted;
  static Color get inkFaint => _palette.inkFaint;

  static Color get success => _palette.success;
  static Color get warning => _palette.warning;
  static Color get danger => _palette.danger;

  static Color domainSoft(Color c) =>
      Color.alphaBlend(c.withValues(alpha: 0.12), surface);
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

  /// Gap between sections. Deliberately generous: the space between groups is
  /// what lets a screen full of numbers feel light instead of dense.
  static const double section = 44;
}

/// Layout constants shared between the shell and everything that scrolls under
/// it.
///
/// The floating nav is drawn over the body (`Scaffold.extendBody`), so a scroll
/// view that ends flush with the viewport ends *underneath* the nav. Every tab
/// used to reserve a hardcoded 96 px for it, which is simply too small — the
/// pill is 66 high, sits 12 above the bottom edge, and on a gesture-navigation
/// phone another ~24 of system inset sits below that. The last card was clipped
/// on all five tabs. Ask [navClearance] instead of guessing.
class AppLayout {
  AppLayout._();

  /// Height of the floating nav pill.
  static const double navBarHeight = 66;

  /// Gap between the pill and the bottom safe-area edge.
  static const double navBarMargin = 12;

  /// Space a scrolling surface must leave at the bottom so the floating nav
  /// never covers its last item, including a breathing gap above the pill.
  ///
  /// Under `Scaffold.extendBody` Flutter already measures the bottom bar and
  /// reports its full height — pill, margin and system inset together — as the
  /// body's `MediaQuery.padding.bottom`. That measured value is authoritative,
  /// so prefer it; the constants below are only a fallback for callers that are
  /// not inside such a Scaffold.
  static double navClearance(BuildContext context) {
    final measured = MediaQuery.paddingOf(context).bottom;
    final assumed =
        navBarHeight + navBarMargin + MediaQuery.viewPaddingOf(context).bottom;
    return (measured > assumed ? measured : assumed) + AppSpacing.lg;
  }
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

  /// Card elevation.
  ///
  /// Shadows do almost no work on a dark background — a black shadow on a
  /// near-black surface is invisible — so dark mode leans on the surface being
  /// lighter than the scaffold and only keeps a faint shadow for depth.
  static List<BoxShadow> get card {
    final opacityScale = AppColors.isDark ? 2.2 : 1.0;
    return [
      BoxShadow(
        color: const Color(0xFF000000)
            .withValues(alpha: 0.07 * opacityScale),
        blurRadius: 20,
        offset: const Offset(0, 8),
      ),
      BoxShadow(
        color: const Color(0xFF000000)
            .withValues(alpha: 0.04 * opacityScale),
        blurRadius: 3,
        offset: const Offset(0, 1),
      ),
    ];
  }

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
