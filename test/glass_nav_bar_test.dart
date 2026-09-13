// containsSemantics is deprecated from Flutter 3.41 in favour of isSemantics,
// which doesn't exist on the pinned 3.38.3 (.flutter-version).
// ignore_for_file: deprecated_member_use

import 'package:ecashapp/widgets/glass_nav_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _harness({double textScale = 1.0}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: Scaffold(
        extendBody: true,
        body: const SizedBox.expand(),
        bottomNavigationBar: GlassNavBar(
          currentIndex: 0,
          onTap: (_) {},
          items: const [
            GlassNavBarItem(icon: Icons.flash_on, label: 'Lightning'),
            GlassNavBarItem(icon: Icons.link, label: 'Onchain'),
            GlassNavBarItem(icon: Icons.currency_bitcoin, label: 'Ecash'),
          ],
        ),
      ),
    ),
  );
}

void main() {
  group('GlassNavBar', () {
    for (final scale in [1.0, 1.5, 2.0, 3.0]) {
      testWidgets('does not overflow at ${scale}x text scale', (tester) async {
        await tester.pumpWidget(_harness(textScale: scale));
        expect(tester.takeException(), isNull);
        expect(find.text('Lightning'), findsOneWidget);
      });
    }

    testWidgets('grows with the text scale', (tester) async {
      await tester.pumpWidget(_harness());
      final base = tester.getSize(find.byType(GlassNavBar)).height;
      // No safe-area inset in the test MediaQuery, so the slot is the pill
      // plus its bottom margin.
      expect(base, GlassNavBar.minHeight + GlassNavBar.bottomMargin);

      await tester.pumpWidget(_harness(textScale: 2.0));
      expect(
        tester.getSize(find.byType(GlassNavBar)).height,
        greaterThan(base),
      );
    });

    testWidgets('announces each tab label once', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_harness());

      expect(
        tester.getSemantics(find.text('Lightning')),
        containsSemantics(
          label: 'Lightning',
          isButton: true,
          isSelected: true,
          hasTapAction: true,
        ),
      );
      expect(
        tester.getSemantics(find.text('Onchain')),
        containsSemantics(
          label: 'Onchain',
          isButton: true,
          isSelected: false,
          hasTapAction: true,
        ),
      );

      handle.dispose();
    });
  });
}
