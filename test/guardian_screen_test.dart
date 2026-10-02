import 'package:ecashapp/generated/app_localizations.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/screens/guardian_screen.dart';
import 'package:ecashapp/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stands in for the Rust-backed selector, which the screen only needs once a
/// button calls into Rust.
class _FakeFederation implements FederationSelector {
  @override
  String get federationName => 'Test Federation';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget harness(Widget child) {
  return MaterialApp(
    theme: cypherpunkNinjaTheme,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: const [Locale('en'), Locale('es')],
    home: child,
  );
}

void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  final es = lookupAppLocalizations(const Locale('es'));
  final now = DateTime(2026, 9, 21, 12);

  GuardianSessionStatus seen(Duration ago, {int sessionCount = 48211}) {
    final firstSeen = now.subtract(ago);
    return GuardianSessionStatus(
      peerId: 0,
      sessionCount: BigInt.from(sessionCount),
      firstSeenAt: BigInt.from(firstSeen.millisecondsSinceEpoch ~/ 1000),
      fresh: true,
      sessionsBehind: BigInt.zero,
      isBehind: false,
    );
  }

  final neverAnswered = GuardianSessionStatus(
    peerId: 1,
    fresh: false,
    sessionsBehind: BigInt.zero,
    isBehind: false,
  );

  group('formatGuardianSessionAge', () {
    test('gives the age in the largest unit that fits', () {
      String? at(Duration ago) =>
          formatGuardianSessionAge(en, seen(ago), now: now);

      expect(at(const Duration(days: 3, hours: 5)), '3 d ago');
      expect(at(const Duration(hours: 26)), '1 d ago');
      expect(at(const Duration(hours: 1, minutes: 59)), '1 h ago');
      expect(at(const Duration(minutes: 45)), '45 min ago');
      expect(at(const Duration(minutes: 1)), '1 min ago');
      expect(
        formatGuardianSessionAge(
          es,
          seen(const Duration(minutes: 45)),
          now: now,
        ),
        'hace 45 min',
      );
    });

    test('reads under a minute, and a clock set back since, as just now', () {
      expect(
        formatGuardianSessionAge(
          en,
          seen(const Duration(seconds: 59)),
          now: now,
        ),
        'just now',
      );
      expect(
        formatGuardianSessionAge(en, seen(const Duration(hours: -2)), now: now),
        'just now',
      );
    });

    test('has nothing to say about a guardian that never answered', () {
      expect(formatGuardianSessionAge(en, null, now: now), isNull);
      expect(formatGuardianSessionAge(en, neverAnswered, now: now), isNull);
    });
  });

  group('guardianSyncState', () {
    GuardianSessionStatus guardian({bool fresh = true, bool isBehind = false}) {
      return GuardianSessionStatus(
        peerId: 0,
        sessionCount: BigInt.from(100),
        firstSeenAt: BigInt.from(now.millisecondsSinceEpoch ~/ 1000),
        fresh: fresh,
        sessionsBehind: BigInt.zero,
        isBehind: isBehind,
      );
    }

    test('is in sync while on the most recent sessions', () {
      expect(
        guardianSyncState(online: true, session: guardian()),
        GuardianSyncState.inSync,
      );
    });

    test('is behind when trailing the others', () {
      expect(
        guardianSyncState(online: true, session: guardian(isBehind: true)),
        GuardianSyncState.behind,
      );
    });

    test('is down when unreachable, whatever it last reported', () {
      expect(
        guardianSyncState(online: false, session: guardian()),
        GuardianSyncState.down,
      );
      expect(
        guardianSyncState(online: false, session: null),
        GuardianSyncState.down,
      );
    });

    test('is unknown while reachable but not reporting this round', () {
      expect(
        guardianSyncState(online: true, session: null),
        GuardianSyncState.unknown,
      );
      expect(
        guardianSyncState(online: true, session: guardian(fresh: false)),
        GuardianSyncState.unknown,
      );
    });
  });

  group('formatGuardianSessionCount', () {
    test('labels the count and groups it the way the locale does', () {
      final status = seen(Duration.zero, sessionCount: 1048211);
      expect(formatGuardianSessionCount(en, status), 'Session 1,048,211');
      expect(formatGuardianSessionCount(es, status), 'Sesión 1.048.211');
    });

    test('has nothing to say about a guardian that never answered', () {
      expect(formatGuardianSessionCount(en, null), isNull);
      expect(formatGuardianSessionCount(en, neverAnswered), isNull);
    });
  });

  group('GuardianScreen', () {
    PeerStatus peer({bool online = true}) => PeerStatus(
      peerId: 0,
      name: 'Alice',
      online: online,
      connectivity: PeerConnectivity.direct,
      url: 'wss://alice.example.com/ws/',
      version: '0.12.0',
    );

    Future<ValueNotifier<List<PeerStatus>?>> pump(
      WidgetTester tester, {
      required PeerStatus guardian,
      GuardianSessionStatus? session,
      bool joinable = false,
    }) async {
      final peers = ValueNotifier<List<PeerStatus>?>([
        guardian,
        PeerStatus(
          peerId: 1,
          name: 'Bob',
          online: true,
          connectivity: PeerConnectivity.direct,
          url: 'wss://bob.example.com/ws/',
        ),
      ]);
      final sessions = ValueNotifier<Map<int, GuardianSessionStatus>>({
        if (session != null) 0: session,
      });
      // A phone, so the layout is checked at the width it ships at.
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      addTearDown(peers.dispose);
      addTearDown(sessions.dispose);
      await tester.pumpWidget(
        harness(
          GuardianScreen(
            fed: _FakeFederation(),
            peer: guardian,
            peers: peers,
            sessions: sessions,
            joinable: joinable,
          ),
        ),
      );
      return peers;
    }

    testWidgets('shows what is known about a guardian and how to log in', (
      tester,
    ) async {
      await pump(
        tester,
        guardian: peer(),
        session: seen(const Duration(minutes: 3), sessionCount: 48211),
      );

      expect(find.text('Alice'), findsWidgets);
      expect(find.text('In sync'), findsOneWidget);
      expect(find.text('48,211'), findsOneWidget);
      expect(find.text('wss://alice.example.com/ws/'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Copy invite code'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Copy invite code'), findsOneWidget);
      final button = tester.widget<ButtonStyleButton>(
        find.ancestor(
          of: find.text('Open Guardian Dashboard'),
          matching: find.bySubtype<ButtonStyleButton>(),
        ),
      );
      expect(button.onPressed, isNotNull);
    });

    testWidgets('cannot log in to a guardian that is offline', (tester) async {
      await pump(tester, guardian: peer(online: false));

      expect(find.text('Offline'), findsWidgets);
      expect(
        find.text('The dashboard is available while the guardian is online'),
        findsOneWidget,
      );
      final button = tester.widget<ButtonStyleButton>(
        find.ancestor(
          of: find.text('Open Guardian Dashboard'),
          matching: find.bySubtype<ButtonStyleButton>(),
        ),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('offers no login or invite code before joining', (
      tester,
    ) async {
      await pump(tester, guardian: peer(), joinable: true);

      expect(find.text('Open Guardian Dashboard'), findsNothing);
      expect(find.text('Copy invite code'), findsNothing);
    });

    testWidgets('follows the guardian while open', (tester) async {
      final peers = await pump(tester, guardian: peer());
      expect(find.text('No report'), findsOneWidget);

      peers.value = [peer(online: false), ...peers.value!.skip(1)];
      await tester.pump();

      expect(find.text('No report'), findsNothing);
      expect(find.text('Offline'), findsWidgets);
    });
  });
}
