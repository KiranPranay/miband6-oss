import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:band/core/logger.dart';
import 'package:band/core/notification_relay.dart';
import 'package:band/ui/notifications_screen.dart';
import 'package:band/ui/theme/app_theme.dart';

/// The app picker used to be a fixed Column with an Expanded list, and a
/// keyboard pushed its bottom off the screen ("upon search, the bottom is
/// overflowed"). It is now one scroll view that folds the setting groups away
/// while you search, so matches sit under the field. These tests pump it at a
/// phone size and at a keyboard-shrunk size and assert nothing overflows,
/// the groups fold and unfold, and the empty state reads back the query.
void main() {
  const apps = [
    AppInfo('com.whatsapp', 'WhatsApp'),
    AppInfo('org.telegram.messenger', 'Telegram'),
    AppInfo('com.google.android.gm', 'Gmail'),
    AppInfo('com.myairtelapp', 'Airtel'),
  ];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<NotificationRelay> pump(WidgetTester t,
      {Size size = const Size(390, 844), double keyboard = 0}) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    final relay = NotificationRelay.detached(
      BLELogger(),
      apps: apps,
      accessGranted: true,
      enabled: true,
      selected: {'com.whatsapp'},
    );
    await t.pumpWidget(
      ChangeNotifierProvider<NotificationRelay>.value(
        value: relay,
        child: MaterialApp(
          theme: AppTheme.light,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(viewInsets: EdgeInsets.only(bottom: keyboard)),
            child: child!,
          ),
          home: const NotificationsScreen(),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    return relay;
  }

  Future<void> scrollTo(WidgetTester t, Finder f) async {
    await t.scrollUntilVisible(f, 120,
        scrollable: find.byType(Scrollable).first);
    await t.pumpAndSettle();
  }

  testWidgets('renders the groups, the field and every app', (t) async {
    await pump(t);
    expect(find.text('ACCESS'), findsOneWidget);
    expect(find.text('FORWARDING'), findsOneWidget);
    expect(find.text('Forward notifications to band'), findsOneWidget);
    expect(find.text('APPS TO FORWARD · 1 SELECTED'), findsOneWidget);
    // The list is lazy and starts below the groups; scroll to it.
    await scrollTo(t, find.text('WhatsApp'));
    expect(find.text('WhatsApp'), findsOneWidget);
    await scrollTo(t, find.text('Airtel'));
    expect(find.text('Airtel'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('search folds the groups away and filters the list',
      (t) async {
    await pump(t);
    await t.enterText(find.byType(TextField), 'wha');
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);

    expect(find.text('FORWARDING'), findsNothing,
        reason: 'the setting groups fold away while searching');
    expect(find.text('1 MATCH · 1 SELECTED'), findsOneWidget);
    expect(find.text('WhatsApp'), findsOneWidget);
    expect(find.text('Telegram'), findsNothing);

    // Package names match too.
    await t.enterText(find.byType(TextField), 'telegram.mess');
    await t.pumpAndSettle();
    expect(find.text('Telegram'), findsOneWidget);
    expect(find.text('WhatsApp'), findsNothing);
  });

  testWidgets('no match reads the query back; clearing restores the groups',
      (t) async {
    await pump(t);
    await t.enterText(find.byType(TextField), 'zzz');
    await t.pumpAndSettle();
    expect(find.text('No app matches "zzz"'), findsOneWidget);
    expect(find.text('0 MATCHES · 1 SELECTED'), findsOneWidget);

    await t.tap(find.byTooltip('Clear search'));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(find.text('FORWARDING'), findsOneWidget);
    expect(find.text('APPS TO FORWARD · 1 SELECTED'), findsOneWidget);
  });

  testWidgets('a keyboard-sized viewport does not overflow', (t) async {
    // 844 tall phone with a 340 px keyboard up: the body is ~500 px.
    await pump(t, keyboard: 340);
    await t.enterText(find.byType(TextField), 'a');
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    // Both Airtel and WhatsApp contain "a"; Gmail does too — the list
    // renders under the field rather than being pushed off the bottom.
    expect(find.text('Airtel'), findsOneWidget);
  });

  testWidgets('a very short viewport still lays out', (t) async {
    await pump(t, size: const Size(360, 420));
    expect(find.byType(TextField), findsOneWidget);
    await t.drag(find.byType(CustomScrollView), const Offset(0, -600));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  });

  testWidgets('ticking an app updates the selected count', (t) async {
    final relay = await pump(t);
    await scrollTo(t, find.text('Telegram'));
    await t.tap(find.text('Telegram'));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(relay.isAppSelected('org.telegram.messenger'), isTrue);
    await scrollTo(t, find.text('APPS TO FORWARD · 2 SELECTED'));
    expect(find.text('APPS TO FORWARD · 2 SELECTED'), findsOneWidget);
  });
}
