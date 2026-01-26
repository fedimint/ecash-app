import 'package:ecashapp/deep_link_handler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseDeepLinkUri', () {
    group('lightning: scheme', () {
      test('parses basic lightning invoice', () {
        final uri = Uri.parse(
          'lightning:lnbc1pvjluezpp5qqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqypqdpl2pkx2ctnv5sxxmmwwd5kgetjypeh2ursdae8g6twvus8g6rfwvs8qun0dfjkxaq',
        );
        final result = parseDeepLinkUri(uri);

        expect(result, isNotNull);
        expect(result!.type, DeepLinkType.lightning);
        expect(result.data, startsWith('lnbc1'));
      });

      test('handles uppercase LIGHTNING scheme (case insensitive)', () {
        final uri = Uri.parse('LIGHTNING:lnbc1test');
        final result = parseDeepLinkUri(uri);

        expect(result, isNotNull);
        expect(result!.type, DeepLinkType.lightning);
        expect(result.data, 'lnbc1test');
      });

      test('returns null for empty lightning data', () {
        final uri = Uri.parse('lightning:');
        final result = parseDeepLinkUri(uri);

        expect(result, isNull);
      });

      test('strips leading slashes from lightning data', () {
        final uri = Uri.parse('lightning:///lnbc1test');
        final result = parseDeepLinkUri(uri);

        expect(result, isNotNull);
        expect(result!.data, 'lnbc1test');
      });
    });

    group('lnurl: scheme', () {
      test('parses basic LNURL', () {
        final uri = Uri.parse(
          'lnurl:LNURL1DP68GURN8GHJ7MRWW4EXCTNXD9SHG6NPVCHXXMMD9AKXUATJDSKHQCTE8AEK2UMND9HKU0FKVESNZDFEX4SNXENZV4JNWWF3VENXVV3SHGDP4X4SKVEPJX56RJEP4VYMNSVF5',
        );
        final result = parseDeepLinkUri(uri);

        expect(result, isNotNull);
        expect(result!.type, DeepLinkType.lnurl);
        expect(result.data, startsWith('LNURL1'));
      });

      test('returns null for empty lnurl data', () {
        final uri = Uri.parse('lnurl:');
        final result = parseDeepLinkUri(uri);

        expect(result, isNull);
      });
    });

    group('lnurlp: scheme', () {
      test('parses lnurlp as lnurl type', () {
        final uri = Uri.parse('lnurlp:LNURL1TEST');
        final result = parseDeepLinkUri(uri);

        expect(result, isNotNull);
        expect(result!.type, DeepLinkType.lnurl);
        expect(result.data, 'LNURL1TEST');
      });
    });

    group('bitcoin: scheme (BIP21)', () {
      test('parses basic bitcoin address', () {
        final uri = Uri.parse(
          'bitcoin:bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq',
        );
        final result = parseDeepLinkUri(uri);

        expect(result, isNotNull);
        expect(result!.type, DeepLinkType.bitcoin);
        expect(result.data, 'bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq');
      });

      test('parses bitcoin address with amount parameter', () {
        final uri = Uri.parse('bitcoin:bc1qtest?amount=0.001');
        final result = parseDeepLinkUri(uri);

        expect(result, isNotNull);
        expect(result!.type, DeepLinkType.bitcoin);
        expect(result.data, 'bc1qtest?amount=0.001');
      });

      test('parses bitcoin address with multiple parameters', () {
        final uri = Uri.parse(
          'bitcoin:bc1qtest?amount=0.001&label=Test&message=Hello',
        );
        final result = parseDeepLinkUri(uri);

        expect(result, isNotNull);
        expect(result!.type, DeepLinkType.bitcoin);
        expect(result.data, contains('amount=0.001'));
        expect(result.data, contains('label=Test'));
      });

      test('parses bitcoin URI with lightning parameter (BIP21 unified)', () {
        final uri = Uri.parse('bitcoin:?lightning=lnbc1test');
        final result = parseDeepLinkUri(uri);

        expect(result, isNotNull);
        expect(result!.type, DeepLinkType.bitcoin);
        expect(result.data, '?lightning=lnbc1test');
      });

      test('parses bitcoin URI with address and lightning parameter', () {
        final uri = Uri.parse('bitcoin:bc1qtest?lightning=lnbc1invoice');
        final result = parseDeepLinkUri(uri);

        expect(result, isNotNull);
        expect(result!.type, DeepLinkType.bitcoin);
        expect(result.data, 'bc1qtest?lightning=lnbc1invoice');
      });

      test('returns null for empty bitcoin data', () {
        final uri = Uri.parse('bitcoin:');
        final result = parseDeepLinkUri(uri);

        expect(result, isNull);
      });

      test('handles uppercase BITCOIN scheme', () {
        final uri = Uri.parse('BITCOIN:bc1qtest');
        final result = parseDeepLinkUri(uri);

        expect(result, isNotNull);
        expect(result!.type, DeepLinkType.bitcoin);
      });
    });

    group('unsupported schemes', () {
      test('returns null for http scheme', () {
        final uri = Uri.parse('http://example.com');
        final result = parseDeepLinkUri(uri);

        expect(result, isNull);
      });

      test('returns null for https scheme', () {
        final uri = Uri.parse('https://example.com');
        final result = parseDeepLinkUri(uri);

        expect(result, isNull);
      });

      test('returns null for mailto scheme', () {
        final uri = Uri.parse('mailto:test@example.com');
        final result = parseDeepLinkUri(uri);

        expect(result, isNull);
      });

      test('returns null for unknown custom scheme', () {
        final uri = Uri.parse('myapp:somedata');
        final result = parseDeepLinkUri(uri);

        expect(result, isNull);
      });
    });

    group('DeepLinkData', () {
      test('toString returns readable format', () {
        final data = DeepLinkData(
          type: DeepLinkType.lightning,
          data: 'lnbc1test',
        );

        expect(
          data.toString(),
          'DeepLinkData(type: DeepLinkType.lightning, data: lnbc1test)',
        );
      });

      test('equality check', () {
        final data1 = DeepLinkData(type: DeepLinkType.lightning, data: 'test');
        final data2 = DeepLinkData(type: DeepLinkType.lightning, data: 'test');
        final data3 = DeepLinkData(type: DeepLinkType.bitcoin, data: 'test');

        // Note: DeepLinkData doesn't implement == so these are different instances
        expect(data1.type, data2.type);
        expect(data1.data, data2.data);
        expect(data1.type, isNot(data3.type));
      });
    });
  });
}
