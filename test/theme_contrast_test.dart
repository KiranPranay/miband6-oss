import 'dart:math';

import 'package:band/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Accessibility guardrail for the colour system.
///
/// WCAG 2.1 contrast is computed from relative luminance:
///   ratio = (L_lighter + 0.05) / (L_darker + 0.05)
/// with 4.5:1 required for normal text and 3:1 for large text and for
/// non-text UI elements (icons, chart marks, focus indicators).
///
/// Both palettes are checked, because a dark theme that merely inverts a light
/// one usually fails: mid-tone accents that read well on white are far too dark
/// on near-black.

double _channel(double c) =>
    c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4).toDouble();

double _luminance(Color c) =>
    0.2126 * _channel(c.r) + 0.7152 * _channel(c.g) + 0.0722 * _channel(c.b);

double contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  final hi = max(la, lb);
  final lo = min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  for (final entry in {
    'light': AppPalette.light,
    'dark': AppPalette.dark,
  }.entries) {
    final name = entry.key;
    final p = entry.value;

    group('$name palette contrast', () {
      test('body text on both surfaces meets 4.5:1', () {
        expect(contrast(p.ink, p.surface), greaterThanOrEqualTo(4.5),
            reason: 'ink on surface');
        expect(contrast(p.ink, p.scaffold), greaterThanOrEqualTo(4.5),
            reason: 'ink on scaffold');
      });

      test('muted secondary text meets 4.5:1', () {
        expect(contrast(p.inkMuted, p.surface), greaterThanOrEqualTo(4.5),
            reason: 'inkMuted on surface');
      });

      test('faint text meets the 3:1 large-text / non-text minimum', () {
        // inkFaint is only used for captions and hints at >=11.5pt semibold and
        // for decorative marks, so 3:1 is the applicable threshold.
        expect(contrast(p.inkFaint, p.surface), greaterThanOrEqualTo(3.0),
            reason: 'inkFaint on surface');
      });

      test('every domain accent is distinguishable on the surface (3:1)', () {
        final accents = <String, Color>{
          'primary': p.primary,
          'heart': p.heart,
          'activity': p.activity,
          'sleep': p.sleep,
          'spo2': p.spo2,
          'stress': p.stress,
          'calories': p.calories,
          'distance': p.distance,
          'success': p.success,
          'warning': p.warning,
          'danger': p.danger,
        };
        accents.forEach((label, c) {
          expect(contrast(c, p.surface), greaterThanOrEqualTo(3.0),
              reason: '$label on surface in $name');
        });
      });

      test('sleep stage colours are distinguishable on the surface', () {
        for (final c in [p.sleepDeep, p.sleepLight, p.sleepRem, p.sleepAwake]) {
          expect(contrast(c, p.surface), greaterThanOrEqualTo(2.5),
              reason: 'sleep stage swatch in $name');
        }
      });

      test('surface is distinguishable from the scaffold behind it', () {
        // Cards are separated from the background by colour as well as shadow —
        // which matters most in dark mode, where shadows do almost nothing.
        expect(contrast(p.surface, p.scaffold), greaterThan(1.05),
            reason: 'card surface vs scaffold in $name');
      });
    });
  }

  group('palette switching', () {
    tearDown(() => AppColors.setPalette(AppPalette.light));

    test('tokens follow the active palette', () {
      AppColors.setPalette(AppPalette.light);
      expect(AppColors.isDark, isFalse);
      final lightInk = AppColors.ink;

      AppColors.setPalette(AppPalette.dark);
      expect(AppColors.isDark, isTrue);
      expect(AppColors.ink, isNot(lightInk));
      expect(contrast(AppColors.ink, AppColors.surface),
          greaterThanOrEqualTo(4.5));
    });

    test('setPalette reports whether anything changed', () {
      AppColors.setPalette(AppPalette.light);
      expect(AppColors.setPalette(AppPalette.light), isFalse);
      expect(AppColors.setPalette(AppPalette.dark), isTrue);
    });

    test('domain hues are recognisably the same across palettes', () {
      // The point of keeping hue stable is that a metric stays identifiable by
      // colour when the user switches theme.
      double hue(Color c) => HSLColor.fromColor(c).hue;
      const pairs = [
        ('heart', AppPalette.light, AppPalette.dark),
      ];
      for (final _ in pairs) {
        expect((hue(AppPalette.light.heart) - hue(AppPalette.dark.heart)).abs(),
            lessThan(25));
        expect((hue(AppPalette.light.sleep) - hue(AppPalette.dark.sleep)).abs(),
            lessThan(25));
        expect(
            (hue(AppPalette.light.stress) - hue(AppPalette.dark.stress)).abs(),
            lessThan(25));
      }
    });
  });
}
