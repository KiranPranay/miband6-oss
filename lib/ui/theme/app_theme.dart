import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'tokens.dart';

/// The light, professional, lively theme for the redesign.
class AppTheme {
  AppTheme._();

  static ThemeData get light {
    final base = ThemeData.light(useMaterial3: true);
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.primary,
      brightness: Brightness.light,
      surface: AppColors.surface,
    ).copyWith(
      primary: AppColors.primary,
      onPrimary: Colors.white,
      surface: AppColors.surface,
      onSurface: AppColors.ink,
    );

    final textTheme = GoogleFonts.manropeTextTheme(base.textTheme).apply(
      bodyColor: AppColors.ink,
      displayColor: AppColors.ink,
    );

    return base.copyWith(
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.scaffold,
      textTheme: textTheme,
      splashFactory: InkSparkle.splashFactory,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        iconTheme: IconThemeData(color: AppColors.ink),
        titleTextStyle: TextStyle(
          color: AppColors.ink,
          fontSize: 20,
          fontWeight: FontWeight.w800,
        ),
      ),
      dividerColor: AppColors.divider,
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? Colors.white : Colors.white,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? AppColors.primary
              : AppColors.inkFaint.withValues(alpha: 0.4),
        ),
      ),
      iconTheme: const IconThemeData(color: AppColors.inkMuted),
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
