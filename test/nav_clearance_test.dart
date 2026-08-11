import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:band/ui/theme/tokens.dart';
import 'package:band/ui/widgets/tab_header.dart';

/// The floating nav is drawn *over* the tab content (`Scaffold.extendBody`), so
/// each tab has to reserve room for it or its last card is clipped. Every tab
/// used to reserve a flat `SizedBox(height: 96)`, which is less than the nav
/// actually occupies once the pill (66), its margin (12) and the phone's
/// gesture inset are added up — so the last card was cut off on all five tabs.
///
/// These tests pin the arithmetic against a Scaffold shaped like the real
/// shell, on a device with a gesture bar.
void main() {
  const gestureInset = 24.0;
  const navTotal =
      AppLayout.navBarHeight + AppLayout.navBarMargin + gestureInset;

  /// A stand-in for `HomeShell`: floating pill over an extended body.
  Widget shell({required Widget child}) => MediaQuery(
        data: const MediaQueryData(
          padding: EdgeInsets.only(bottom: gestureInset),
          viewPadding: EdgeInsets.only(bottom: gestureInset),
        ),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Scaffold(
            extendBody: true,
            body: child,
            bottomNavigationBar: const SafeArea(
              top: false,
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, AppLayout.navBarMargin),
                child: SizedBox(height: AppLayout.navBarHeight),
              ),
            ),
          ),
        ),
      );

  testWidgets('clearance covers the whole nav, not just the pill',
      (tester) async {
    late double clearance;
    await tester.pumpWidget(shell(
      child: Builder(builder: (context) {
        clearance = AppLayout.navClearance(context);
        return const SizedBox.shrink();
      }),
    ));

    expect(clearance, greaterThanOrEqualTo(navTotal),
        reason: 'anything less leaves the last card partly behind the nav');
    expect(clearance, greaterThan(96),
        reason: 'the old hardcoded 96 is the bug being fixed here');
    // A gap above the pill, but not a screenful of dead space.
    expect(clearance - navTotal, inInclusiveRange(8, 32));
  });

  testWidgets('SliverNavClearance reserves exactly that much', (tester) async {
    late double expected;
    await tester.pumpWidget(shell(
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Builder(builder: (context) {
              expected = AppLayout.navClearance(context);
              return const SizedBox(height: 100);
            }),
          ),
          const SliverNavClearance(),
        ],
      ),
    ));

    final spacer = find.descendant(
      of: find.byType(SliverNavClearance),
      matching: find.byType(SizedBox),
    );
    expect(tester.getSize(spacer).height, expected);
  });

  testWidgets('falls back sanely with no Scaffold to measure', (tester) async {
    late double clearance;
    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(
        viewPadding: EdgeInsets.only(bottom: gestureInset),
      ),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(builder: (context) {
          clearance = AppLayout.navClearance(context);
          return const SizedBox.shrink();
        }),
      ),
    ));

    expect(clearance, greaterThanOrEqualTo(navTotal));
  });
}
