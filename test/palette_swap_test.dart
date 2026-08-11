import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:band/ui/theme/tokens.dart';
import 'package:band/ui/widgets/section_header.dart';

/// Regression tests for the stale-palette bug.
///
/// The design tokens are process-wide getters read at *build* time, and Flutter
/// does not rebuild a `const` widget whose instance has not changed. So a const
/// widget first built under the wrong palette keeps those colours indefinitely.
///
/// On a real cold start Android reports `platformBrightness == light` for the
/// first frame or two before correcting itself, which froze whatever had been
/// built by then into light-mode colours on a dark screen: section headings in
/// #161B2E on a #0E1017 background, and a #FFFFFF card in the middle of the
/// Heart tab. Sections built later came out correct, which is why the result
/// looked arbitrary rather than like a single bug.
///
/// The fix is to key the subtree on the palette so a change *discards* the
/// elements instead of updating them. These tests pin both halves: that the
/// naive tree really does go stale (so the guard is not decorative), and that
/// the keyed one does not.
void main() {
  /// Mirrors `_PaletteGate` in main.dart.
  Widget gate({required Brightness brightness, required Widget child}) {
    AppColors.setPalette(
        brightness == Brightness.dark ? AppPalette.dark : AppPalette.light);
    return MaterialApp(
      home: Scaffold(
        body: KeyedSubtree(key: ValueKey(brightness), child: child),
      ),
    );
  }

  Color headingColor(WidgetTester tester) {
    final text = tester.widget<Text>(find.text('Recommendations'));
    return text.style!.color!;
  }

  tearDown(() => AppColors.setPalette(AppPalette.light));

  testWidgets('const section header follows a light → dark palette swap',
      (tester) async {
    await tester.pumpWidget(gate(
        brightness: Brightness.light,
        child: const SectionHeader('Recommendations')));
    expect(headingColor(tester), AppPalette.light.ink);

    await tester.pumpWidget(gate(
        brightness: Brightness.dark,
        child: const SectionHeader('Recommendations')));

    expect(headingColor(tester), AppPalette.dark.ink,
        reason: 'heading kept the light-mode ink after the palette changed — '
            'this is the near-invisible-heading bug');
  });

  testWidgets('and back again, dark → light', (tester) async {
    await tester.pumpWidget(gate(
        brightness: Brightness.dark,
        child: const SectionHeader('Recommendations')));
    expect(headingColor(tester), AppPalette.dark.ink);

    await tester.pumpWidget(gate(
        brightness: Brightness.light,
        child: const SectionHeader('Recommendations')));
    expect(headingColor(tester), AppPalette.light.ink);
  });

  testWidgets('without the key the const subtree really does go stale',
      (tester) async {
    // Guards the guard: if Flutter ever started rebuilding identical const
    // widgets, `_PaletteGate` would be dead weight and this test would fail,
    // prompting someone to check rather than leave it in forever.
    Widget naive(Brightness b) {
      AppColors.setPalette(
          b == Brightness.dark ? AppPalette.dark : AppPalette.light);
      return const MaterialApp(
        home: Scaffold(body: SectionHeader('Recommendations')),
      );
    }

    await tester.pumpWidget(naive(Brightness.light));
    await tester.pumpWidget(naive(Brightness.dark));

    expect(headingColor(tester), AppPalette.light.ink,
        reason: 'const widgets are not rebuilt on an identical-instance '
            'update, which is exactly why _PaletteGate keys the subtree');
  });

  test('the two palettes are actually distinguishable', () {
    // The tests above would pass vacuously if light and dark shared an ink or
    // a surface colour.
    expect(AppPalette.light.ink, isNot(AppPalette.dark.ink));
    expect(AppPalette.light.surface, isNot(AppPalette.dark.surface));
  });
}
