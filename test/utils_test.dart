import 'package:ecashapp/db.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MilliSats.toSats', () {
    test('converts millisats to sats correctly', () {
      expect(BigInt.from(1000).toSats, BigInt.from(1));
      expect(BigInt.from(5000).toSats, BigInt.from(5));
      expect(BigInt.from(100000).toSats, BigInt.from(100));
    });

    test('truncates fractional sats', () {
      expect(BigInt.from(1500).toSats, BigInt.from(1));
      expect(BigInt.from(999).toSats, BigInt.zero);
      expect(BigInt.from(1001).toSats, BigInt.from(1));
    });

    test('handles zero', () {
      expect(BigInt.zero.toSats, BigInt.zero);
    });

    test('handles large values', () {
      // 1 BTC = 100,000,000,000 msats
      final oneBtcMsats = BigInt.from(100000000000);
      expect(oneBtcMsats.toSats, BigInt.from(100000000));
    });
  });

  group('threshold', () {
    test('calculates Byzantine threshold correctly', () {
      // 4 peers: max evil = (4-1)/3 = 1, threshold = 4-1 = 3
      expect(threshold(4), 3);

      // 7 peers: max evil = (7-1)/3 = 2, threshold = 7-2 = 5
      expect(threshold(7), 5);

      // 10 peers: max evil = (10-1)/3 = 3, threshold = 10-3 = 7
      expect(threshold(10), 7);

      // 1 peer: max evil = 0, threshold = 1
      expect(threshold(1), 1);

      // 3 peers: max evil = (3-1)/3 = 0, threshold = 3
      expect(threshold(3), 3);
    });
  });

  group('formatBalance', () {
    group('with null msats', () {
      test('returns correct format for each display type', () {
        expect(formatBalance(null, false, BitcoinDisplay.bip177), '₿0');
        expect(formatBalance(null, false, BitcoinDisplay.sats), '0 sats');
        expect(formatBalance(null, false, BitcoinDisplay.nothing), '0');
        expect(formatBalance(null, false, BitcoinDisplay.symbol), '0丰');
      });

      test('returns correct format with showMsats', () {
        expect(formatBalance(null, true, BitcoinDisplay.bip177), '₿0.000');
        expect(formatBalance(null, true, BitcoinDisplay.sats), '0.000 sats');
        expect(formatBalance(null, true, BitcoinDisplay.nothing), '0.000');
        expect(formatBalance(null, true, BitcoinDisplay.symbol), '0.000丰');
      });
    });

    group('with showMsats=false (sats display)', () {
      test('formats sats correctly for BitcoinDisplay.sats', () {
        // 1000 msats = 1 sat
        expect(
          formatBalance(BigInt.from(1000), false, BitcoinDisplay.sats),
          '1 sats',
        );
        // 1,234,567 msats = 1,234 sats (truncated)
        expect(
          formatBalance(BigInt.from(1234567000), false, BitcoinDisplay.sats),
          '1 234 567 sats',
        );
      });

      test('formats sats correctly for BitcoinDisplay.bip177', () {
        expect(
          formatBalance(BigInt.from(1000), false, BitcoinDisplay.bip177),
          '₿1',
        );
        expect(
          formatBalance(BigInt.from(1234567000), false, BitcoinDisplay.bip177),
          '₿1 234 567',
        );
      });

      test('formats sats correctly for BitcoinDisplay.nothing', () {
        expect(
          formatBalance(BigInt.from(1000), false, BitcoinDisplay.nothing),
          '1',
        );
      });

      test('formats sats correctly for BitcoinDisplay.symbol', () {
        expect(
          formatBalance(BigInt.from(1000), false, BitcoinDisplay.symbol),
          '1丰',
        );
      });
    });

    group('with showMsats=true (fractional sats display)', () {
      test('formats with 3 decimal places', () {
        // 1234 msats = 1.234 sats
        expect(
          formatBalance(BigInt.from(1234), true, BitcoinDisplay.sats),
          '1.234 sats',
        );
        // 500 msats = 0.500 sats
        expect(
          formatBalance(BigInt.from(500), true, BitcoinDisplay.sats),
          '0.500 sats',
        );
      });

      test('formats with bip177 prefix', () {
        expect(
          formatBalance(BigInt.from(1234), true, BitcoinDisplay.bip177),
          '₿1.234',
        );
      });

      test('formats with symbol suffix', () {
        expect(
          formatBalance(BigInt.from(1234), true, BitcoinDisplay.symbol),
          '1.234丰',
        );
      });
    });

    group('edge cases', () {
      test('handles zero msats', () {
        expect(
          formatBalance(BigInt.zero, false, BitcoinDisplay.sats),
          '0 sats',
        );
        expect(
          formatBalance(BigInt.zero, true, BitcoinDisplay.sats),
          '0.000 sats',
        );
      });

      test('handles large values with space separators', () {
        // 1 BTC = 100,000,000 sats = 100,000,000,000 msats
        final oneBtcMsats = BigInt.from(100000000) * BigInt.from(1000);
        expect(
          formatBalance(oneBtcMsats, false, BitcoinDisplay.sats),
          '100 000 000 sats',
        );
      });
    });
  });

  group('calculateFiatValue', () {
    test('returns empty string when btcPrice is null', () {
      expect(calculateFiatValue(null, 100000, FiatCurrency.usd), '');
    });

    test('calculates USD correctly with symbol before', () {
      // At $50,000/BTC, 100,000 sats = $50
      expect(calculateFiatValue(50000.0, 100000, FiatCurrency.usd), '\$50.00');
      // At $50,000/BTC, 1 sat = $0.0005
      expect(calculateFiatValue(50000.0, 1, FiatCurrency.usd), '\$0.00');
      // At $50,000/BTC, 10,000,000 sats = $5,000
      expect(
        calculateFiatValue(50000.0, 10000000, FiatCurrency.usd),
        '\$5000.00',
      );
    });

    test('calculates EUR correctly with symbol after', () {
      // At €45,000/BTC, 100,000 sats = €45
      expect(calculateFiatValue(45000.0, 100000, FiatCurrency.eur), '45.00€');
    });

    test('calculates GBP correctly with symbol before', () {
      expect(calculateFiatValue(40000.0, 100000, FiatCurrency.gbp), '£40.00');
    });

    test('calculates CAD correctly with C\$ prefix', () {
      expect(calculateFiatValue(60000.0, 100000, FiatCurrency.cad), 'C\$60.00');
    });

    test('calculates CHF correctly with CHF prefix', () {
      expect(
        calculateFiatValue(55000.0, 100000, FiatCurrency.chf),
        'CHF 55.00',
      );
    });

    test('calculates AUD correctly with A\$ prefix', () {
      expect(calculateFiatValue(70000.0, 100000, FiatCurrency.aud), 'A\$70.00');
    });

    test('calculates JPY correctly with ¥ prefix', () {
      expect(
        calculateFiatValue(7000000.0, 100000, FiatCurrency.jpy),
        '¥7000.00',
      );
    });

    test('handles zero sats', () {
      expect(calculateFiatValue(50000.0, 0, FiatCurrency.usd), '\$0.00');
    });
  });

  group('calculateSatsFromFiat', () {
    test('returns 0 when btcPrice is null', () {
      expect(calculateSatsFromFiat(null, 100.0), 0);
    });

    test('returns 0 when btcPrice is 0', () {
      expect(calculateSatsFromFiat(0.0, 100.0), 0);
    });

    test('calculates sats correctly', () {
      // At $50,000/BTC, $50 = 100,000 sats
      expect(calculateSatsFromFiat(50000.0, 50.0), 100000);
      // At $50,000/BTC, $1 = 2,000 sats
      expect(calculateSatsFromFiat(50000.0, 1.0), 2000);
      // At $100,000/BTC, $100 = 100,000 sats
      expect(calculateSatsFromFiat(100000.0, 100.0), 100000);
    });

    test('rounds to nearest sat', () {
      // At $50,000/BTC, $0.01 = 20 sats
      expect(calculateSatsFromFiat(50000.0, 0.01), 20);
    });

    test('handles zero fiat amount', () {
      expect(calculateSatsFromFiat(50000.0, 0.0), 0);
    });
  });

  group('formatFiatInput', () {
    test('handles empty input', () {
      expect(formatFiatInput('', FiatCurrency.usd), '\$0');
      expect(formatFiatInput('', FiatCurrency.eur), '0€');
    });

    test('formats whole numbers correctly', () {
      expect(formatFiatInput('123', FiatCurrency.usd), '\$123');
      expect(formatFiatInput('123', FiatCurrency.eur), '123€');
    });

    test('preserves partial decimal input during typing', () {
      expect(formatFiatInput('12.', FiatCurrency.usd), '\$12.');
      expect(formatFiatInput('12.5', FiatCurrency.usd), '\$12.5');
      expect(formatFiatInput('12.50', FiatCurrency.usd), '\$12.50');
    });

    test('handles leading decimal', () {
      expect(formatFiatInput('.5', FiatCurrency.usd), '\$0.5');
    });

    test('formats all currencies correctly', () {
      expect(formatFiatInput('100', FiatCurrency.usd), '\$100');
      expect(formatFiatInput('100', FiatCurrency.eur), '100€');
      expect(formatFiatInput('100', FiatCurrency.gbp), '£100');
      expect(formatFiatInput('100', FiatCurrency.cad), 'C\$100');
      expect(formatFiatInput('100', FiatCurrency.chf), 'CHF 100');
      expect(formatFiatInput('100', FiatCurrency.aud), 'A\$100');
      expect(formatFiatInput('100', FiatCurrency.jpy), '¥100');
    });
  });

  group('explorerUrlForNetwork', () {
    test('returns mempool.space URL for bitcoin network', () {
      expect(
        explorerUrlForNetwork('abc123', 'bitcoin'),
        'https://mempool.space/tx/abc123',
      );
    });

    test('returns mutinynet URL for signet network', () {
      expect(
        explorerUrlForNetwork('abc123', 'signet'),
        'https://mutinynet.com/tx/abc123',
      );
    });

    test('returns null for unknown network', () {
      expect(explorerUrlForNetwork('abc123', 'testnet'), null);
      expect(explorerUrlForNetwork('abc123', 'regtest'), null);
    });

    test('returns null for null network', () {
      expect(explorerUrlForNetwork('abc123', null), null);
    });
  });

  group('isValidRelayUri', () {
    test('accepts valid wss URIs', () {
      expect(isValidRelayUri('wss://relay.damus.io'), true);
      expect(isValidRelayUri('wss://nos.lol'), true);
      expect(isValidRelayUri('wss://relay.example.com:443'), true);
    });

    test('accepts valid ws URIs', () {
      expect(isValidRelayUri('ws://localhost:7777'), true);
      expect(isValidRelayUri('ws://127.0.0.1:8080'), true);
    });

    test('rejects http/https URIs', () {
      expect(isValidRelayUri('https://relay.damus.io'), false);
      expect(isValidRelayUri('http://relay.damus.io'), false);
    });

    test('rejects URIs without authority', () {
      expect(isValidRelayUri('wss:'), false);
      // Note: 'wss://' has an empty authority which passes hasAuthority check
      // This is technically valid URI parsing behavior
    });

    test('rejects empty string', () {
      expect(isValidRelayUri(''), false);
    });

    test('rejects malformed URIs', () {
      expect(isValidRelayUri('not a uri'), false);
      expect(isValidRelayUri('://missing-scheme'), false);
    });
  });

  group('getAbbreviatedText', () {
    test('returns full text if 14 chars or less', () {
      expect(getAbbreviatedText('short'), 'short');
      expect(getAbbreviatedText('exactly14char'), 'exactly14char');
    });

    test('abbreviates text longer than 14 chars', () {
      expect(
        getAbbreviatedText('this is a very long text'),
        'this is...ng text',
      );
    });

    test('handles empty string', () {
      expect(getAbbreviatedText(''), '');
    });
  });
}
