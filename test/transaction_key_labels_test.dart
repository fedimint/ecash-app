import 'dart:io';

import 'package:ecashapp/constants/transaction_key_labels.dart';
import 'package:ecashapp/constants/transaction_keys.dart';
import 'package:ecashapp/generated/app_localizations.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every constant declared in TransactionDetailKeys, read from the source.
///
/// Enumerating the class itself is not possible without mirrors, and a
/// hand-copied list would silently stop covering a key the moment someone adds
/// one — which is the exact drift this file exists to catch.
Map<String, String> readTransactionDetailKeys() {
  final source = File('lib/constants/transaction_keys.dart');
  if (!source.existsSync()) {
    throw StateError(
      'run from the package root so the constants can be enumerated',
    );
  }

  final matches = RegExp(
    r"""static const String (\w+)\s*=\s*['"]([^'"]*)['"];""",
  ).allMatches(source.readAsStringSync());

  return {for (final m in matches) m.group(1)!: m.group(2)!};
}

void main() {
  final keys = readTransactionDetailKeys();
  final en = lookupAppLocalizations(const Locale('en'));
  final es = lookupAppLocalizations(const Locale('es'));

  /// Keys whose Spanish label is deliberately the same text as the raw key, so
  /// they cannot be told apart from the untranslated fallback.
  const identicalInSpanish = {
    TransactionDetailKeys.ecash,
    TransactionDetailKeys.lnurl,
    TransactionDetailKeys.total,
  };

  group('TransactionDetailKeys enumeration', () {
    test('finds every declared constant', () {
      expect(
        keys.length,
        28,
        reason:
            'a key was added or removed — confirm localizedTxLabel handles it, '
            'then update this count',
      );
      expect(keys['amount'], TransactionDetailKeys.amount);
      expect(keys['dust'], TransactionDetailKeys.dust);
    });

    test('the raw values are unique', () {
      // They double as Map keys in the transaction detail payloads, so a
      // collision would make one field overwrite another.
      expect(keys.values.toSet().length, keys.length);
    });

    test('every constant has a switch arm in localizedTxLabel', () {
      final labels =
          File('lib/constants/transaction_key_labels.dart').readAsStringSync();

      final missing =
          keys.keys
              .where(
                (name) =>
                    !RegExp(
                      'TransactionDetailKeys\\.$name\\b',
                    ).hasMatch(labels),
              )
              .toList();

      expect(missing, isEmpty, reason: 'these keys would render untranslated');
    });
  });

  group('localizedTxLabel en', () {
    test('every key resolves to a non-empty label', () {
      for (final entry in keys.entries) {
        expect(
          localizedTxLabel(en, entry.value),
          isNotEmpty,
          reason: 'key ${entry.key}',
        );
      }
    });

    test('labels are distinct across keys', () {
      // Two keys sharing an arm is the usual copy-paste slip in the switch, and
      // it shows up as a duplicated row in the transaction details.
      final labels = keys.values.map((k) => localizedTxLabel(en, k)).toList();

      expect(labels.toSet().length, labels.length);
    });

    test('resolves representative keys', () {
      expect(localizedTxLabel(en, TransactionDetailKeys.amount), 'Amount');
      expect(
        localizedTxLabel(en, TransactionDetailKeys.onchainClaimFee),
        'On-chain Claim Fee',
      );
      expect(
        localizedTxLabel(en, TransactionDetailKeys.payeePublicKey),
        'Payee Pubkey',
      );
      expect(localizedTxLabel(en, TransactionDetailKeys.dust), 'Dust');
    });

    test('reuses the receive screen labels for the deposit fee breakdown', () {
      expect(
        localizedTxLabel(en, TransactionDetailKeys.federationBaseFee),
        en.federationBaseFee,
      );
      expect(
        localizedTxLabel(en, TransactionDetailKeys.federationRate),
        en.federationRate,
      );
    });
  });

  group('localizedTxLabel es', () {
    test('every key resolves to a non-empty label', () {
      for (final entry in keys.entries) {
        expect(
          localizedTxLabel(es, entry.value),
          isNotEmpty,
          reason: 'key ${entry.key}',
        );
      }
    });

    test('every key is actually translated, not falling through', () {
      // The fallback arm returns the raw key, so a key with no switch arm (or
      // no Spanish string behind it) shows English text to a Spanish user.
      for (final entry in keys.entries) {
        if (identicalInSpanish.contains(entry.value)) continue;
        expect(
          localizedTxLabel(es, entry.value),
          isNot(entry.value),
          reason: 'key ${entry.key} looks untranslated',
        );
      }
    });

    test('labels are distinct across keys', () {
      final labels = keys.values.map((k) => localizedTxLabel(es, k)).toList();

      expect(labels.toSet().length, labels.length);
    });

    test('resolves representative keys', () {
      expect(localizedTxLabel(es, TransactionDetailKeys.amount), 'Monto');
      expect(
        localizedTxLabel(es, TransactionDetailKeys.gatewayFee),
        'Comisión de Pasarela',
      );
      expect(localizedTxLabel(es, TransactionDetailKeys.dust), 'Polvo');
    });
  });

  group('localizedTxLabel fallback', () {
    test('returns the raw key when nothing matches', () {
      expect(localizedTxLabel(en, 'Not A Key'), 'Not A Key');
      expect(localizedTxLabel(es, 'Not A Key'), 'Not A Key');
    });

    test('returns an empty key unchanged', () {
      expect(localizedTxLabel(en, ''), '');
    });

    test('matching is exact, not case- or whitespace-insensitive', () {
      // The values are Map keys at runtime, so near-misses are real bugs the
      // fallback would otherwise hide behind plausible-looking text.
      expect(localizedTxLabel(en, 'amount'), 'amount');
      expect(localizedTxLabel(en, 'Amount '), 'Amount ');
    });
  });
}
