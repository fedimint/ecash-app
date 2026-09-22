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

  group('summarizeConsensus', () {
    GuardianSessionStatus guardian(
      int sessionCount,
      Duration ago, {
      bool fresh = true,
      bool isBehind = false,
    }) {
      return GuardianSessionStatus(
        peerId: 0,
        sessionCount: BigInt.from(sessionCount),
        firstSeenAt: BigInt.from(
          now.subtract(ago).millisecondsSinceEpoch ~/ 1000,
        ),
        fresh: fresh,
        sessionsBehind: BigInt.zero,
        isBehind: isBehind,
      );
    }

    test('sorts guardians in sync first and unanswered ones last', () {
      final summary = summarizeConsensus([
        null,
        guardian(98, const Duration(hours: 2), isBehind: true),
        guardian(100, const Duration(minutes: 1)),
        guardian(100, const Duration(days: 1), fresh: false),
        guardian(99, const Duration(minutes: 4)),
      ], now: now);

      expect(summary.states, [
        GuardianSyncState.inSync,
        GuardianSyncState.inSync,
        GuardianSyncState.behind,
        GuardianSyncState.unknown,
        GuardianSyncState.unknown,
      ]);
      expect(summary.inSync, 2);
    });

    test('dates the most advanced session from when it was first seen', () {
      final summary = summarizeConsensus([
        guardian(100, const Duration(minutes: 2)),
        guardian(100, const Duration(minutes: 3)),
        // Older, but on an earlier session, so it says nothing about the tip.
        guardian(99, const Duration(hours: 5)),
        // On the tip longest of all, but it did not answer this round.
        guardian(100, const Duration(days: 1), fresh: false),
      ], now: now);

      expect(summary.tipAge, const Duration(minutes: 3));
      expect(summary.isStalled, isFalse);
    });

    test('reports a stall however well the guardians agree', () {
      final summary = summarizeConsensus([
        guardian(100, const Duration(minutes: 47)),
        guardian(100, const Duration(minutes: 47)),
        guardian(100, const Duration(minutes: 47)),
      ], now: now);

      expect(summary.inSync, 3);
      expect(summary.isStalled, isTrue);
      expect(
        summarizeConsensus([
          guardian(100, consensusStalledAfter - const Duration(seconds: 1)),
        ], now: now).isStalled,
        isFalse,
      );
    });

    test('knows nothing until a guardian has answered', () {
      final summary = summarizeConsensus([
        null,
        guardian(100, const Duration(hours: 1), fresh: false),
      ], now: now);

      expect(summary.tipAge, isNull);
      expect(summary.isStalled, isFalse);
      expect(summary.inSync, 0);
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
