import 'package:ecashapp/generated/app_localizations.dart';
import 'package:ecashapp/providers/preferences_provider.dart';
import 'package:ecashapp/screens/federation_expiry_screen.dart';
import 'package:ecashapp/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

BigInt unixSeconds(DateTime t) => BigInt.from(t.millisecondsSinceEpoch ~/ 1000);

/// Hosts the screen under the app theme, localizations and the preferences
/// provider its balance row reads. The provider's Rust-backed load fails under
/// `flutter test` and falls back to defaults, which is all the row needs.
Widget harness(Widget child) {
  return ChangeNotifierProvider(
    create: (_) => PreferencesProvider(),
    child: MaterialApp(
      theme: cypherpunkNinjaTheme,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('en'), Locale('es')],
      home: child,
    ),
  );
}

/// Records which of the screen's flows were invoked, and lets a test decide
/// what the loaders report once a flow has run.
class Flows {
  int sendOnchain = 0;
  int openLightningAddress = 0;
  int leave = 0;
  BigInt? balanceAfter;
  String? addressAfter;
}

void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  final now = DateTime(2026, 9, 14, 12);

  group('formatTimeUntilExpiry', () {
    test('uses the largest unit that still gives a whole number', () {
      String at(Duration ahead) =>
          formatTimeUntilExpiry(en, now.add(ahead), now: now);

      expect(at(const Duration(days: 3, hours: 5)), '3 days');
      expect(at(const Duration(days: 1)), '1 day');
      expect(at(const Duration(hours: 23, minutes: 59)), '23 hours');
      expect(at(const Duration(hours: 1)), '1 hour');
      expect(at(const Duration(minutes: 45)), '45 minutes');
      expect(at(const Duration(minutes: 1)), '1 minute');
    });

    test('reports a passed deadline rather than a negative count', () {
      expect(
        formatTimeUntilExpiry(
          en,
          now.subtract(const Duration(hours: 2)),
          now: now,
        ),
        en.federationExpiryPassed,
      );
    });
  });

  group('FederationExpiryScreen', () {
    final inAMonth = unixSeconds(DateTime.now().add(const Duration(days: 30)));
    final lastWeek = unixSeconds(
      DateTime.now().subtract(const Duration(days: 7)),
    );
    const address = 'alice@example.com';

    Future<Flows> pumpScreen(
      WidgetTester tester, {
      BigInt? expiryTimestamp,
      String? successorInvite,
      BigInt? balanceMsats,
      String? lightningAddress,
    }) async {
      // Tall enough that the whole list, links included, is laid out.
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final flows =
          Flows()
            ..balanceAfter = balanceMsats
            ..addressAfter = lightningAddress;
      await tester.pumpWidget(
        harness(
          FederationExpiryScreen(
            // A fresh state per pump, as a fresh push gives it in the app;
            // otherwise a second pump updates the first screen in place.
            key: UniqueKey(),
            federationName: 'Old Fed',
            expiryTimestamp: expiryTimestamp,
            successorInvite: successorInvite,
            balanceMsats: balanceMsats,
            lightningAddress: lightningAddress,
            loadBalance: () async => flows.balanceAfter,
            loadLightningAddress: () async => flows.addressAfter,
            onSendOnchain: () async => flows.sendOnchain++,
            onOpenLightningAddress: () async => flows.openLightningAddress++,
            onJoin: (_, _) {},
            onLeaveFederation: () async => flows.leave++,
          ),
        ),
      );
      await tester.pump();
      return flows;
    }

    double top(WidgetTester tester, String text) =>
        tester.getTopLeft(find.text(text)).dy;

    testWidgets('lists only the steps that still apply', (tester) async {
      await pumpScreen(tester, expiryTimestamp: inAMonth);
      expect(find.text(en.federationExpirySendOnchain), findsNothing);
      expect(
        find.text(en.federationExpiryManageLightningAddress),
        findsNothing,
      );
      expect(find.text(en.federationExpiryFindFederation), findsOneWidget);
      expect(find.text(en.leaveFederation), findsOneWidget);
    });

    testWidgets('puts moving the balance first while there is one', (
      tester,
    ) async {
      await pumpScreen(
        tester,
        expiryTimestamp: inAMonth,
        balanceMsats: BigInt.from(21_000),
        lightningAddress: address,
      );
      expect(find.text(en.federationExpiryStepMoveFunds), findsOneWidget);
      expect(
        top(tester, en.federationExpirySendOnchain),
        lessThan(top(tester, en.federationExpiryManageLightningAddress)),
      );

      await pumpScreen(
        tester,
        expiryTimestamp: inAMonth,
        balanceMsats: BigInt.zero,
      );
      expect(find.text(en.federationExpirySendOnchain), findsNothing);
    });

    testWidgets(
      'links the Lightning Address step only while one is registered',
      (tester) async {
        await pumpScreen(
          tester,
          expiryTimestamp: inAMonth,
          lightningAddress: address,
          successorInvite: 'fed11successor',
        );
        expect(
          find.text(en.federationExpiryStepRemoveLightningAddress(address)),
          findsOneWidget,
        );
        expect(
          top(tester, en.federationExpiryManageLightningAddress),
          lessThan(top(tester, en.federationExpiryJoinSuccessor)),
        );

        await pumpScreen(tester, expiryTimestamp: inAMonth);
        expect(find.textContaining(address), findsNothing);
      },
    );

    testWidgets('offers the successor when named, discovery otherwise', (
      tester,
    ) async {
      await pumpScreen(
        tester,
        expiryTimestamp: inAMonth,
        successorInvite: 'fed11successor',
      );
      expect(find.text(en.federationExpiryStepJoinSuccessor), findsOneWidget);
      expect(find.text(en.federationExpiryJoinSuccessor), findsOneWidget);
      expect(find.text(en.federationExpiryFindFederation), findsNothing);
      expect(
        top(tester, en.federationExpiryJoinSuccessor),
        lessThan(top(tester, en.leaveFederation)),
      );

      await pumpScreen(tester, expiryTimestamp: inAMonth);
      expect(find.text(en.federationExpiryStepJoinAnother), findsOneWidget);
      expect(find.text(en.federationExpiryFindFederation), findsOneWidget);
      expect(find.text(en.federationExpiryJoinSuccessor), findsNothing);
    });

    testWidgets('sending on-chain runs the flow and re-reads the balance', (
      tester,
    ) async {
      final flows = await pumpScreen(
        tester,
        expiryTimestamp: inAMonth,
        balanceMsats: BigInt.from(21_000),
      );
      flows.balanceAfter = BigInt.zero;

      await tester.tap(find.text(en.federationExpirySendOnchain));
      await tester.pumpAndSettle();

      expect(flows.sendOnchain, 1);
      // Nothing left to move, so the step is gone and the balance row agrees.
      expect(find.text(en.federationExpirySendOnchain), findsNothing);
      expect(find.text(en.federationExpiryYourBalance), findsOneWidget);
    });

    testWidgets('managing the address runs the flow and re-reads it', (
      tester,
    ) async {
      final flows = await pumpScreen(
        tester,
        expiryTimestamp: inAMonth,
        lightningAddress: address,
      );
      flows.addressAfter = null;

      await tester.tap(find.text(en.federationExpiryManageLightningAddress));
      await tester.pumpAndSettle();

      expect(flows.openLightningAddress, 1);
      expect(find.textContaining(address), findsNothing);
    });

    testWidgets('leaving is handed to the caller', (tester) async {
      final flows = await pumpScreen(tester, expiryTimestamp: inAMonth);
      await tester.tap(find.text(en.leaveFederation));
      await tester.pumpAndSettle();
      expect(flows.leave, 1);
    });

    testWidgets('shows the date and time left for a future shutdown', (
      tester,
    ) async {
      await pumpScreen(tester, expiryTimestamp: inAMonth);
      expect(find.text(en.federationExpiryHeadline('Old Fed')), findsOneWidget);
      expect(find.text(en.federationExpiryClosesOn), findsOneWidget);
      expect(find.text(en.federationExpiryTimeRemaining), findsOneWidget);
    });

    testWidgets('speaks in the past tense once the date has gone by', (
      tester,
    ) async {
      await pumpScreen(tester, expiryTimestamp: lastWeek);
      expect(
        find.text(en.federationExpiryHeadlinePast('Old Fed')),
        findsOneWidget,
      );
      expect(find.text(en.federationExpiryClosedOn), findsOneWidget);
      expect(find.text(en.federationExpiryTimeRemaining), findsNothing);
    });

    testWidgets('omits the date rows when only a successor is set', (
      tester,
    ) async {
      await pumpScreen(tester, successorInvite: 'fed11successor');
      expect(find.text(en.federationExpiryHeadline('Old Fed')), findsOneWidget);
      expect(find.text(en.federationExpiryClosesOn), findsNothing);
      expect(find.text(en.federationExpiryTimeRemaining), findsNothing);
      expect(find.text(en.federationExpiryYourBalance), findsOneWidget);
    });
  });
}
