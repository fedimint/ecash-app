import 'package:ecashapp/generated/app_localizations.dart';
import 'package:ecashapp/models.dart';
import 'package:ecashapp/multimint.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Covers the user-facing text of a recovery history row.
///
/// The row itself (`TransactionItem`) cannot be pumped in a unit test — it
/// needs a `FederationSelector`, whose federation id is an opaque Rust handle
/// that only exists once `RustLib.init()` has loaded the native library — so
/// what is testable here is the text the row and its toast are built from.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  final es = lookupAppLocalizations(const Locale('es'));

  group('RecoveryModule label', () {
    test('names every module in both locales', () {
      // Exhaustive over the enum on purpose: a module added on the Rust side
      // regenerates this enum, and an unhandled arm would otherwise surface as
      // a runtime error inside a history row rather than here.
      for (final module in RecoveryModule.values) {
        expect(module.label(en), isNotEmpty, reason: '$module in English');
        expect(module.label(es), isNotEmpty, reason: '$module in Spanish');
      }
    });

    test('reuses the payment-type names the rest of the UI uses', () {
      // A recovery row sits inside a payment-type tab, so it has to name its
      // module the same way that tab does rather than inventing a synonym.
      expect(RecoveryModule.ecash.label(en), en.ecash);
      expect(RecoveryModule.onchain.label(en), en.onchain);
      expect(RecoveryModule.lightning.label(en), en.lightning);
    });

    test('the three modules are told apart', () {
      final labels = RecoveryModule.values.map((m) => m.label(en)).toSet();

      expect(labels.length, RecoveryModule.values.length);
    });
  });

  group('recovery strings', () {
    test('the amount and module both reach the message', () {
      // Both placeholders have to survive translation: a Spanish string that
      // dropped one would silently hide how much was recovered.
      for (final l10n in [en, es]) {
        final message = l10n.recoveryCompleteWithAmount(
          '1,234 sats',
          RecoveryModule.ecash.label(l10n),
        );

        expect(message, contains('1,234 sats'));
        expect(message, contains(RecoveryModule.ecash.label(l10n)));
      }
    });

    test('the amount-less message still names the module', () {
      // The wallet module recovers without reporting a total, so this is the
      // variant an on-chain recovery always takes.
      for (final l10n in [en, es]) {
        final message = l10n.recoveryCompleteWithoutAmount(
          RecoveryModule.onchain.label(l10n),
        );

        expect(message, contains(RecoveryModule.onchain.label(l10n)));
      }
    });

    test('a row is labelled as a recovery, not as a payment', () {
      // The history row reuses `txReceived`/`txSent` for payments; a recovery
      // must not be mistakable for either of them.
      for (final l10n in [en, es]) {
        expect(l10n.txRecovered, isNotEmpty);
        expect(l10n.txRecovered, isNot(l10n.txReceived));
        expect(l10n.txRecovered, isNot(l10n.txSent));
      }
    });

    test('an unreported amount reads as unknown rather than as zero', () {
      for (final l10n in [en, es]) {
        expect(l10n.txRecoveredAmountUnknown, isNotEmpty);
      }
      expect(es.txRecoveredAmountUnknown, isNot(en.txRecoveredAmountUnknown));
    });
  });
}
