import 'package:ecashapp/generated/app_localizations.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/screens/federation_info_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
