import 'package:ecashapp/models.dart';
import 'package:ecashapp/utils/amount_validation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isValidAmount', () {
    test('returns false when balance is loading', () {
      expect(
        isValidAmount(
          rawAmount: '100',
          loadingBalance: true,
          currentBalance: BigInt.from(1000000),
          paymentType: PaymentType.lightning,
          isLightningReceive: false,
        ),
        false,
      );
    });

    test('returns false for empty amount', () {
      expect(
        isValidAmount(
          rawAmount: '',
          loadingBalance: false,
          currentBalance: BigInt.from(1000000),
          paymentType: PaymentType.lightning,
          isLightningReceive: false,
        ),
        false,
      );
    });

    test('returns false for zero amount', () {
      expect(
        isValidAmount(
          rawAmount: '0',
          loadingBalance: false,
          currentBalance: BigInt.from(1000000),
          paymentType: PaymentType.lightning,
          isLightningReceive: false,
        ),
        false,
      );
    });

    test('returns false for invalid amount string', () {
      expect(
        isValidAmount(
          rawAmount: 'abc',
          loadingBalance: false,
          currentBalance: BigInt.from(1000000),
          paymentType: PaymentType.lightning,
          isLightningReceive: false,
        ),
        false,
      );
    });

    group('lightning receive', () {
      test('returns true for any positive amount (no balance check)', () {
        expect(
          isValidAmount(
            rawAmount: '999999999',
            loadingBalance: false,
            currentBalance: BigInt.from(1000), // tiny balance
            paymentType: PaymentType.lightning,
            isLightningReceive: true,
          ),
          true,
        );
      });

      test('returns true even with null balance', () {
        expect(
          isValidAmount(
            rawAmount: '100',
            loadingBalance: false,
            currentBalance: null,
            paymentType: PaymentType.lightning,
            isLightningReceive: true,
          ),
          true,
        );
      });
    });

    group('lightning send', () {
      test('returns true when amount is within balance', () {
        // 100 sats = 100,000 msats, balance is 1,000,000 msats
        expect(
          isValidAmount(
            rawAmount: '100',
            loadingBalance: false,
            currentBalance: BigInt.from(1000000),
            paymentType: PaymentType.lightning,
            isLightningReceive: false,
          ),
          true,
        );
      });

      test('returns true when amount equals balance exactly', () {
        // 1000 sats = 1,000,000 msats
        expect(
          isValidAmount(
            rawAmount: '1000',
            loadingBalance: false,
            currentBalance: BigInt.from(1000000),
            paymentType: PaymentType.lightning,
            isLightningReceive: false,
          ),
          true,
        );
      });

      test('returns false when amount exceeds balance', () {
        // 1001 sats = 1,001,000 msats > 1,000,000 msats
        expect(
          isValidAmount(
            rawAmount: '1001',
            loadingBalance: false,
            currentBalance: BigInt.from(1000000),
            paymentType: PaymentType.lightning,
            isLightningReceive: false,
          ),
          false,
        );
      });

      test('returns true when balance is null (error will be caught later)', () {
        expect(
          isValidAmount(
            rawAmount: '100',
            loadingBalance: false,
            currentBalance: null,
            paymentType: PaymentType.lightning,
            isLightningReceive: false,
          ),
          true,
        );
      });
    });

    group('ecash send', () {
      test('returns true when amount is within balance', () {
        expect(
          isValidAmount(
            rawAmount: '500',
            loadingBalance: false,
            currentBalance: BigInt.from(1000000),
            paymentType: PaymentType.ecash,
            isLightningReceive: false,
          ),
          true,
        );
      });

      test('returns false when amount exceeds balance', () {
        expect(
          isValidAmount(
            rawAmount: '2000',
            loadingBalance: false,
            currentBalance: BigInt.from(1000000),
            paymentType: PaymentType.ecash,
            isLightningReceive: false,
          ),
          false,
        );
      });
    });

    group('onchain send', () {
      test('returns true when amount is within balance', () {
        expect(
          isValidAmount(
            rawAmount: '500',
            loadingBalance: false,
            currentBalance: BigInt.from(1000000),
            paymentType: PaymentType.onchain,
            isLightningReceive: false,
          ),
          true,
        );
      });

      test('returns false when amount exceeds balance', () {
        expect(
          isValidAmount(
            rawAmount: '2000',
            loadingBalance: false,
            currentBalance: BigInt.from(1000000),
            paymentType: PaymentType.onchain,
            isLightningReceive: false,
          ),
          false,
        );
      });
    });
  });

  group('isAmountOverBalance', () {
    test('returns false when loading', () {
      expect(
        isAmountOverBalance(
          rawAmount: '999999',
          loadingBalance: true,
          currentBalance: BigInt.from(1000),
          isLightningReceive: false,
        ),
        false,
      );
    });

    test('returns false when balance is null', () {
      expect(
        isAmountOverBalance(
          rawAmount: '999999',
          loadingBalance: false,
          currentBalance: null,
          isLightningReceive: false,
        ),
        false,
      );
    });

    test('returns false for empty amount', () {
      expect(
        isAmountOverBalance(
          rawAmount: '',
          loadingBalance: false,
          currentBalance: BigInt.from(1000000),
          isLightningReceive: false,
        ),
        false,
      );
    });

    test('returns false for zero amount', () {
      expect(
        isAmountOverBalance(
          rawAmount: '0',
          loadingBalance: false,
          currentBalance: BigInt.from(1000000),
          isLightningReceive: false,
        ),
        false,
      );
    });

    test('returns false for lightning receive', () {
      expect(
        isAmountOverBalance(
          rawAmount: '999999',
          loadingBalance: false,
          currentBalance: BigInt.from(1000),
          isLightningReceive: true,
        ),
        false,
      );
    });

    test('returns false when amount is within balance', () {
      expect(
        isAmountOverBalance(
          rawAmount: '500',
          loadingBalance: false,
          currentBalance: BigInt.from(1000000),
          isLightningReceive: false,
        ),
        false,
      );
    });

    test('returns false when amount equals balance', () {
      expect(
        isAmountOverBalance(
          rawAmount: '1000',
          loadingBalance: false,
          currentBalance: BigInt.from(1000000),
          isLightningReceive: false,
        ),
        false,
      );
    });

    test('returns true when amount exceeds balance', () {
      expect(
        isAmountOverBalance(
          rawAmount: '1001',
          loadingBalance: false,
          currentBalance: BigInt.from(1000000),
          isLightningReceive: false,
        ),
        true,
      );
    });
  });

  group('getRemainingBalance', () {
    test('returns null when loading', () {
      expect(
        getRemainingBalance(
          rawAmount: '100',
          loadingBalance: true,
          currentBalance: BigInt.from(1000000),
        ),
        null,
      );
    });

    test('returns null when balance is null', () {
      expect(
        getRemainingBalance(
          rawAmount: '100',
          loadingBalance: false,
          currentBalance: null,
        ),
        null,
      );
    });

    test('returns full balance when no amount entered', () {
      expect(
        getRemainingBalance(
          rawAmount: '',
          loadingBalance: false,
          currentBalance: BigInt.from(1000000),
        ),
        BigInt.from(1000000),
      );
    });

    test('returns full balance for invalid amount', () {
      expect(
        getRemainingBalance(
          rawAmount: 'abc',
          loadingBalance: false,
          currentBalance: BigInt.from(1000000),
        ),
        BigInt.from(1000000),
      );
    });

    test('calculates remaining balance correctly', () {
      // 100 sats = 100,000 msats, remaining = 1,000,000 - 100,000 = 900,000
      expect(
        getRemainingBalance(
          rawAmount: '100',
          loadingBalance: false,
          currentBalance: BigInt.from(1000000),
        ),
        BigInt.from(900000),
      );
    });

    test('returns zero when amount equals balance', () {
      expect(
        getRemainingBalance(
          rawAmount: '1000',
          loadingBalance: false,
          currentBalance: BigInt.from(1000000),
        ),
        BigInt.zero,
      );
    });

    test('clamps to zero when amount exceeds balance', () {
      expect(
        getRemainingBalance(
          rawAmount: '2000',
          loadingBalance: false,
          currentBalance: BigInt.from(1000000),
        ),
        BigInt.zero,
      );
    });
  });

  group('canAddFiatDigit', () {
    test('returns true for null input', () {
      expect(canAddFiatDigit(null), true);
    });

    test('returns true for empty input', () {
      expect(canAddFiatDigit(''), true);
    });

    test('returns true for whole number (no decimal)', () {
      expect(canAddFiatDigit('123'), true);
    });

    test('returns true when no digits after decimal', () {
      expect(canAddFiatDigit('12.'), true);
    });

    test('returns true when one digit after decimal', () {
      expect(canAddFiatDigit('12.5'), true);
    });

    test('returns false when two digits after decimal', () {
      expect(canAddFiatDigit('12.50'), false);
    });

    test('returns false when more than two digits after decimal', () {
      expect(canAddFiatDigit('12.567'), false);
    });
  });
}
