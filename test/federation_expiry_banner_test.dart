import 'package:ecashapp/generated/app_localizations.dart';
import 'package:ecashapp/screens/federation_expiry_screen.dart';
import 'package:ecashapp/theme.dart';
import 'package:ecashapp/widgets/federation_expiry_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

/// Hosts [child] under the real app theme and localizations at [textScale],
/// top-aligned so the measured height is the banner's own, not the screen's.
Widget harness(Widget child, {double textScale = 1.0}) {
  return MaterialApp(
    theme: cypherpunkNinjaTheme,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: const [Locale('en'), Locale('es')],
    home: Builder(
      builder:
          (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: Scaffold(
              body: Align(alignment: Alignment.topCenter, child: child),
            ),
          ),
    ),
  );
}

BigInt unixSeconds(DateTime t) => BigInt.from(t.millisecondsSinceEpoch ~/ 1000);

/// The date exactly as the banner prints it, so the assertions do not depend
/// on the test's locale settings agreeing with a hand-written string.
String bannerDate(BigInt unixSeconds) =>
    DateFormat.yMMMd().format(expiryDateTime(unixSeconds));

void main() {
  final inAMonth = unixSeconds(DateTime.now().add(const Duration(days: 30)));
  final lastWeek = unixSeconds(
    DateTime.now().subtract(const Duration(days: 7)),
  );

  group('FederationExpiryBanner', () {
    // The dashboard's pinned header declares this height before the banner is
    // measured, so the two must agree at every font scale a user can pick, and
    // neither text line may be squeezed to make that true.
    for (final scale in [0.85, 1.0, 1.3, 2.0]) {
      testWidgets('fills exactly the extent it declares at text scale $scale', (
        tester,
      ) async {
        await tester.pumpWidget(
          harness(
            FederationExpiryBanner(expiryTimestamp: inAMonth, onTap: () {}),
            textScale: scale,
          ),
        );
        expect(tester.takeException(), isNull);

        final banner = find.byType(FederationExpiryBanner);
        final context = tester.element(banner);
        expect(
          tester.getSize(banner).height,
          moreOrLessEquals(
            federationExpiryBannerExtent(context),
            epsilon: 0.01,
          ),
        );

        final texts = find.descendant(of: banner, matching: find.byType(Text));
        expect(texts, findsNWidgets(2));
        for (final text in texts.evaluate()) {
          final paragraph = tester.renderObject<RenderParagraph>(
            find.byWidget(text.widget),
          );
          expect(
            paragraph.size.height,
            greaterThanOrEqualTo(paragraph.textSize.height - 0.01),
            reason: 'a line was clipped to fit the declared extent',
          );
        }
      });
    }

    testWidgets('names the closing date while it is still ahead', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness(
          FederationExpiryBanner(expiryTimestamp: inAMonth, onTap: () {}),
        ),
      );
      final l10n = AppLocalizations.of(
        tester.element(find.byType(FederationExpiryBanner)),
      );
      expect(
        find.text(
          '${l10n.federationExpiryBannerSubtitle(bannerDate(inAMonth))} '
          '${l10n.federationExpiryBannerTap}',
        ),
        findsOneWidget,
      );
    });

    testWidgets('switches to past tense once the date has gone by', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness(
          FederationExpiryBanner(expiryTimestamp: lastWeek, onTap: () {}),
        ),
      );
      final l10n = AppLocalizations.of(
        tester.element(find.byType(FederationExpiryBanner)),
      );
      expect(
        find.text(
          '${l10n.federationExpiryBannerSubtitlePast(bannerDate(lastWeek))} '
          '${l10n.federationExpiryBannerTap}',
        ),
        findsOneWidget,
      );
    });

    testWidgets('explains a successor when there is no date', (tester) async {
      await tester.pumpWidget(
        harness(FederationExpiryBanner(expiryTimestamp: null, onTap: () {})),
      );
      final l10n = AppLocalizations.of(
        tester.element(find.byType(FederationExpiryBanner)),
      );
      expect(
        find.text(
          '${l10n.federationExpiryBannerSubtitleSuccessor} '
          '${l10n.federationExpiryBannerTap}',
        ),
        findsOneWidget,
      );
    });

    testWidgets('reads as information on a join preview', (tester) async {
      await tester.pumpWidget(
        harness(
          FederationExpiryBanner(
            expiryTimestamp: inAMonth,
            onTap: null,
            compact: false,
            note: 'Join only to recover funds you already hold here.',
          ),
          textScale: 1.3,
        ),
      );
      expect(tester.takeException(), isNull);
      final l10n = AppLocalizations.of(
        tester.element(find.byType(FederationExpiryBanner)),
      );
      // No promise of details that a tap cannot deliver, and no chevron.
      expect(find.textContaining(l10n.federationExpiryBannerTap), findsNothing);
      expect(find.byIcon(Icons.chevron_right), findsNothing);
      // The note is there and the line was allowed to wrap rather than clip.
      final subtitle = tester.renderObject<RenderParagraph>(
        find.textContaining('recover funds'),
      );
      expect(subtitle.size.height, greaterThan(subtitle.textSize.height / 2));
      expect(subtitle.textSize.height, greaterThan(20 * 1.3));
    });

    testWidgets('is tappable across its whole surface', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        harness(
          FederationExpiryBanner(
            expiryTimestamp: inAMonth,
            onTap: () => taps++,
          ),
        ),
      );
      await tester.tap(find.byType(FederationExpiryBanner));
      expect(taps, 1);
    });
  });
}
