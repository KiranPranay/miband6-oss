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

    final textTheme = GoogleFonts.instrumentSansTextTheme(base.textTheme).apply(
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
        titleTextStyle: GoogleFonts.fraunces(
          color: p.ink,
          fontSize: 22,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.4,
        ),
      ),
      dividerColor: p.divider,
      switchTheme: SwitchThemeData(
        // The thumb has to contrast with the track it sits on, and in dark mode
        // the "on" track is a light indigo — a white thumb on it left the switch
        // looking like a solid featureless pill, so an enabled toggle was harder
        // to read than a disabled one. Use the scheme's on-primary when
        // selected, which is dark in dark mode and white in light mode.
        thumbColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected)
                ? (p.brightness == Brightness.dark
                    ? const Color(0xFF10121A)
                    : Colors.white)
                : Colors.white),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? p.primary
              : p.inkFaint.withValues(alpha: 0.4),
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? p.primary : p.inkFaint),
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

/// Named text styles for consistent hierarchy.
///
/// Three voices, each with a job:
///
/// * **Fraunces** for display — headings and the hero figures. A soft serif
///   with real character; at light weights and large sizes it reads as an
///   editorial page rather than a dashboard, and it is the one thing that makes
///   the app not look like every other health app.
/// * **Instrument Sans** for everything you read — labels, body, captions —
///   with tabular figures switched on so a column of values still aligns.
/// * **DM Mono**, light, for the evidence lines only. The previous JetBrains
///   Mono at 700 on every number was the heaviest thing on the screen; numbers
///   now share the serif at the top and the sans in the rows.
///
/// Weights top out at 600. Nothing on a screen should shout.
class AppText {
  AppText._();

  static const List<FontFeature> _tabular = [FontFeature.tabularFigures()];

  static TextStyle get metricHero => GoogleFonts.fraunces(
        fontSize: 60,
        fontWeight: FontWeight.w500,
        height: 1.0,
        color: AppColors.ink,
        letterSpacing: -2.4,
        fontFeatures: _tabular,
      );

  static TextStyle get metric => GoogleFonts.fraunces(
        fontSize: 34,
        fontWeight: FontWeight.w500,
        height: 1.0,
        color: AppColors.ink,
        letterSpacing: -1.2,
        fontFeatures: _tabular,
      );

  static TextStyle get metricSm => GoogleFonts.fraunces(
        fontSize: 24,
        fontWeight: FontWeight.w500,
        height: 1.05,
        color: AppColors.ink,
        letterSpacing: -0.6,
        fontFeatures: _tabular,
      );

  /// A number in a ledger row or inline with prose.
  static TextStyle get figure => GoogleFonts.instrumentSans(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: AppColors.ink,
        fontFeatures: _tabular,
      );

  /// Evidence lines ("412 samples · synced 3m ago").
  static TextStyle get mono => GoogleFonts.dmMono(
        fontSize: 11,
        fontWeight: FontWeight.w400,
        color: AppColors.inkFaint,
        letterSpacing: 0.1,
      );

  /// Tracked-out uppercase group label.
  static TextStyle get overline => GoogleFonts.instrumentSans(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: AppColors.inkFaint,
        letterSpacing: 1.4,
      );

  static TextStyle get h1 => GoogleFonts.fraunces(
        fontSize: 30,
        fontWeight: FontWeight.w600,
        color: AppColors.ink,
        letterSpacing: -0.8,
        height: 1.1,
      );

  /// Section header inside a screen — one level down from [h1].
  static TextStyle get sectionTitle => GoogleFonts.fraunces(
        fontSize: 21,
        fontWeight: FontWeight.w600,
        color: AppColors.ink,
        letterSpacing: -0.4,
      );

  static TextStyle get title => GoogleFonts.instrumentSans(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: AppColors.ink,
      );

  static TextStyle get body => GoogleFonts.instrumentSans(
        fontSize: 15,
        fontWeight: FontWeight.w400,
        color: AppColors.ink,
        height: 1.4,
        fontFeatures: _tabular,
      );

  static TextStyle get label => GoogleFonts.instrumentSans(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: AppColors.inkMuted,
        fontFeatures: _tabular,
      );

  static TextStyle get caption => GoogleFonts.instrumentSans(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        color: AppColors.inkFaint,
        letterSpacing: 0.1,
        height: 1.35,
        fontFeatures: _tabular,
      );

  static TextStyle get unit => GoogleFonts.instrumentSans(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: AppColors.inkMuted,
      );
}
