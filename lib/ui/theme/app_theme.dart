import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'tokens.dart';

/// The app's light and dark themes.
///
/// Both are produced by the same builder from an [AppPalette], so the two can
/// never drift apart structurally — only their colours differ.
///
/// Note that [AppColors] must already be pointing at the matching palette when
/// a theme is built (see `ThemedApp` in `main.dart`), because the token getters
/// resolve against the *active* palette rather than taking one as an argument.
class AppTheme {
  AppTheme._();

  static ThemeData get light => _build(AppPalette.light);

  static ThemeData get dark => _build(AppPalette.dark);

  static ThemeData _build(AppPalette p) {
    final base = p.brightness == Brightness.dark
        ? ThemeData.dark(useMaterial3: true)
        : ThemeData.light(useMaterial3: true);

    final scheme = ColorScheme.fromSeed(
      seedColor: p.primary,
      brightness: p.brightness,
      surface: p.surface,
    ).copyWith(
      primary: p.primary,
      onPrimary: p.brightness == Brightness.dark ? const Color(0xFF10121A) : Colors.white,
      surface: p.surface,
      onSurface: p.ink,
      error: p.danger,
    );

    final textTheme = GoogleFonts.manropeTextTheme(base.textTheme).apply(
      bodyColor: p.ink,
      displayColor: p.ink,
    );

    return base.copyWith(
      colorScheme: scheme,
      scaffoldBackgroundColor: p.scaffold,
      textTheme: textTheme,
      splashFactory: InkSparkle.splashFactory,
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        iconTheme: IconThemeData(color: p.ink),
        titleTextStyle: TextStyle(
          color: p.ink,
          fontSize: 20,
          fontWeight: FontWeight.w800,
        ),
      ),
      dividerColor: p.divider,
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) => Colors.white),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? p.primary
              : p.inkFaint.withValues(alpha: 0.4),
        ),
      ),
      iconTheme: IconThemeData(color: p.inkMuted),
      // 48dp minimum touch targets everywhere (WCAG / Material target size).
      materialTapTargetSize: MaterialTapTargetSize.padded,
      listTileTheme: ListTileThemeData(
        iconColor: p.inkMuted,
        textColor: p.ink,
        minVerticalPadding: 10,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: p.surfaceAlt,
        contentTextStyle: TextStyle(color: p.ink),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

/// Named text styles for consistent hierarchy. Big friendly metric numbers,
/// quiet labels.
class AppText {
  AppText._();

  static TextStyle get metricHero => GoogleFonts.manrope(
        fontSize: 52,
        fontWeight: FontWeight.w800,
        height: 1.0,
        color: AppColors.ink,
        letterSpacing: -1.5,
      );

  static TextStyle get metric => GoogleFonts.manrope(
        fontSize: 30,
        fontWeight: FontWeight.w800,
        height: 1.0,
        color: AppColors.ink,
        letterSpacing: -0.8,
      );

  static TextStyle get metricSm => GoogleFonts.manrope(
        fontSize: 22,
        fontWeight: FontWeight.w800,
        height: 1.05,
        color: AppColors.ink,
        letterSpacing: -0.4,
      );

  static TextStyle get h1 => GoogleFonts.manrope(
        fontSize: 24,
        fontWeight: FontWeight.w800,
        color: AppColors.ink,
        letterSpacing: -0.4,
      );

  static TextStyle get title => GoogleFonts.manrope(
        fontSize: 16,
        fontWeight: FontWeight.w700,
        color: AppColors.ink,
      );

  static TextStyle get body => GoogleFonts.manrope(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: AppColors.ink,
      );

  static TextStyle get label => GoogleFonts.manrope(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: AppColors.inkMuted,
      );

  static TextStyle get caption => GoogleFonts.manrope(
        fontSize: 11.5,
        fontWeight: FontWeight.w600,
        color: AppColors.inkFaint,
        letterSpacing: 0.2,
      );

  static TextStyle get unit => GoogleFonts.manrope(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        color: AppColors.inkMuted,
      );
}
