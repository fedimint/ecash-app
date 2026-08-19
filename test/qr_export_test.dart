import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ecashapp/qr_export.dart';
import 'package:ecashapp/qr_loop_session.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List bytes(List<int> b) => Uint8List.fromList(b);

/// One decoded animated-QR data frame.
class QrFrame {
  final int nonce;
  final int totalFrames;
  final int frameIndex;
  final Uint8List data;

  QrFrame(this.nonce, this.totalFrames, this.frameIndex, this.data);
}

/// Reads a frame exactly the way the scanner does.
///
/// Mirrors the header parse in `_handleQrLoopChunk` (lib/scan.dart): one nonce
/// byte, then two big-endian uint16s, then the chunk. Kept as a copy so the
/// round-trip test below fails if either side of the wire format moves.
QrFrame parseDataFrame(String base64Str) {
  final raw = base64Decode(base64Str);
  return QrFrame(
    raw[0],
    (raw[1] << 8) + raw[2],
    (raw[3] << 8) + raw[4],
    Uint8List.fromList(raw.sublist(5)),
  );
}

/// Runs frames through the real decoder and unwraps the result.
///
/// The tail of this is `_processMerged` (lib/scan.dart): a 4-byte big-endian
/// length, a 16-byte md5, then the payload — with the md5 checked, so a payload
/// that comes back here is one the scanner would have accepted.
Uint8List decodeFrames(List<String> frames) {
  final first = parseDataFrame(frames.first);
  final session = QrLoopSession(
    nonce: first.nonce,
    totalFrames: first.totalFrames,
  );

  for (final frame in frames) {
    final parsed = parseDataFrame(frame);
    expect(
      parsed.nonce,
      first.nonce,
      reason: 'one loop must carry a single nonce',
    );
    expect(parsed.totalFrames, first.totalFrames);
    session.addDataFrame(parsed.frameIndex, parsed.data);
  }

  expect(session.isComplete, isTrue);
  final merged = session.mergeChunks();

  final declaredLength =
      (merged[0] << 24) | (merged[1] << 16) | (merged[2] << 8) | merged[3];
  final hash = merged.sublist(4, 20);
  final payload = merged.sublist(20, 20 + declaredLength);
  expect(md5.convert(payload).bytes, hash, reason: 'md5 header must verify');
  return Uint8List.fromList(payload);
}

void main() {
  group('cutAndPad', () {
    test('splits data into chunks of the requested size', () {
      final chunks = cutAndPad(bytes([1, 2, 3, 4, 5, 6]), 3);

      expect(chunks.length, 2);
      expect(chunks[0], bytes([1, 2, 3]));
      expect(chunks[1], bytes([4, 5, 6]));
    });

    test('zero-pads the final chunk up to the full size', () {
      // Every frame has to be the same length: the decoder concatenates chunks
      // blind and recovers the real length from the wrapper header instead.
      final chunks = cutAndPad(bytes([1, 2, 3, 4, 5]), 4);

      expect(chunks.length, 2);
      expect(chunks[0], bytes([1, 2, 3, 4]));
      expect(chunks[1], bytes([5, 0, 0, 0]));
      expect(chunks[1].length, 4);
    });

    test('pads a single short chunk', () {
      final chunks = cutAndPad(bytes([9]), 5);

      expect(chunks.length, 1);
      expect(chunks[0], bytes([9, 0, 0, 0, 0]));
    });

    test('leaves an exact multiple unpadded', () {
      final chunks = cutAndPad(bytes([1, 2, 3, 4]), 2);

      expect(chunks.length, 2);
      expect(chunks[1], bytes([3, 4]));
    });

    test('emits one chunk when the data is smaller than the chunk size', () {
      final chunks = cutAndPad(bytes([1, 2]), 100);

      expect(chunks.length, 1);
      expect(chunks[0].length, 100);
    });

    test('an empty buffer is outside its contract', () {
      // Documents current behaviour rather than endorsing it: zero chunks means
      // the padding step indexes chunks[-1]. Unreachable through dataToFrames,
      // which always has the 20-byte wrapper header to chunk.
      expect(() => cutAndPad(bytes([]), 4), throwsA(isA<RangeError>()));
    });
  });

  group('wrapData', () {
    test('prefixes a big-endian length and the payload md5', () {
      final data = bytes([0xDE, 0xAD, 0xBE, 0xEF]);
      final wrapped = wrapData(data);

      expect(wrapped.length, 4 + 16 + data.length);
      expect(wrapped.sublist(0, 4), bytes([0, 0, 0, 4]));
      expect(wrapped.sublist(4, 20), md5.convert(data).bytes);
      expect(wrapped.sublist(20), data);
    });

    test('writes the length across all four bytes', () {
      // 0x00010203 = 66051 — catches a length field truncated to one or two
      // bytes, which would silently cut a large transfer short.
      final data = Uint8List(66051);
      final wrapped = wrapData(data);

      expect(wrapped.sublist(0, 4), bytes([0x00, 0x01, 0x02, 0x03]));
    });

    test('handles empty data', () {
      final wrapped = wrapData(bytes([]));

      expect(wrapped.length, 20);
      expect(wrapped.sublist(0, 4), bytes([0, 0, 0, 0]));
      expect(wrapped.sublist(4, 20), md5.convert(<int>[]).bytes);
    });
  });

  group('makeDataFrame', () {
    test('lays out nonce, totalFrames, frameIndex, then payload', () {
      final frame = makeDataFrame(
        data: bytes([0xAA, 0xBB]),
        nonce: 7,
        totalFrames: 258, // 0x0102
        frameIndex: 513, // 0x0201
      );

      expect(
        base64Decode(frame),
        bytes([7, 0x01, 0x02, 0x02, 0x01, 0xAA, 0xBB]),
      );
    });

    test('uses a 5-byte header', () {
      final frame = makeDataFrame(
        data: Uint8List(100),
        nonce: 0,
        totalFrames: 1,
        frameIndex: 0,
      );

      expect(base64Decode(frame).length, 105);
    });

    test('keeps the high byte of a 16-bit field', () {
      final frame = makeDataFrame(
        data: bytes([]),
        nonce: 255,
        totalFrames: 4096,
        frameIndex: 4095,
      );

      expect(base64Decode(frame), bytes([255, 0x10, 0x00, 0x0F, 0xFF]));
    });
  });

  group('dataToFrames', () {
    test('accepts a String and a Uint8List interchangeably', () {
      final fromString = dataToFrames('hello world');
      final fromBytes = dataToFrames(
        Uint8List.fromList(utf8.encode('hello world')),
      );

      expect(fromString, fromBytes);
    });

    test('frames declare a count matching how many were emitted', () {
      // 1000 bytes of payload + the 20-byte wrapper = 1020, so 11 chunks of 100.
      final frames = dataToFrames('x' * 1000);

      expect(frames.length, 11);
      for (var i = 0; i < frames.length; i++) {
        final parsed = parseDataFrame(frames[i]);
        expect(parsed.totalFrames, 11);
        expect(parsed.frameIndex, i);
        expect(parsed.data.length, 100);
      }
    });

    test('repeats the loop with an incrementing nonce', () {
      final frames = dataToFrames('x' * 150, loops: 3);

      // 150 + 20 = 170 bytes => 2 chunks per loop.
      expect(frames.length, 6);
      expect(frames.map((f) => parseDataFrame(f).nonce), [0, 0, 1, 1, 2, 2]);
      // Only the nonce changes; the payload of each loop is identical.
      expect(parseDataFrame(frames[2]).data, parseDataFrame(frames[0]).data);
      expect(parseDataFrame(frames[5]).data, parseDataFrame(frames[1]).data);
    });

    test('wraps the nonce at MAX_NONCE', () {
      final frames = dataToFrames('x', loops: MAX_NONCE + 2);

      expect(frames.length, MAX_NONCE + 2);
      expect(parseDataFrame(frames[MAX_NONCE - 1]).nonce, MAX_NONCE - 1);
      expect(parseDataFrame(frames[MAX_NONCE]).nonce, 0);
      expect(parseDataFrame(frames[MAX_NONCE + 1]).nonce, 1);
    });

    test('honours a custom dataSize', () {
      final frames = dataToFrames('x' * 20, dataSize: 10);

      // 20 + 20 = 40 bytes => 4 chunks of 10.
      expect(frames.length, 4);
      expect(parseDataFrame(frames[0]).data.length, 10);
    });
  });

  group('dataToFrames round trip through QrLoopSession', () {
    test('a multi-frame payload comes back byte for byte', () {
      const payload =
          'AgEEZmVkaTEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWYwMTIzNDU2Nzg5';
      final data = Uint8List.fromList(utf8.encode(payload * 20));

      final decoded = decodeFrames(dataToFrames(data));

      expect(decoded, data);
    });

    test('a String payload survives the round trip as UTF-8', () {
      const text = 'ecash notes — with a non-ASCII dash and an emoji 🛰';

      final decoded = decodeFrames(dataToFrames(text));

      expect(utf8.decode(decoded), text);
    });

    test('binary payloads with 0x00 and 0xFF survive', () {
      // Padding writes zeros, and the wrapper length is what tells them apart
      // from real trailing zeros in the data.
      final data = Uint8List.fromList([
        ...List<int>.generate(256, (i) => i),
        0,
        0,
        0,
      ]);

      expect(decodeFrames(dataToFrames(data)), data);
    });

    test('frames arriving out of order still reassemble', () {
      // A camera sees the loop from wherever the user points it.
      final data = Uint8List.fromList(utf8.encode('out of order ' * 40));
      final frames = dataToFrames(data);

      expect(frames.length, greaterThan(3));
      expect(decodeFrames(frames.reversed.toList()), data);
    });

    test('duplicate frames do not corrupt the result', () {
      final data = Uint8List.fromList(utf8.encode('duplicated ' * 30));
      final frames = dataToFrames(data);

      expect(decodeFrames([...frames, ...frames]), data);
    });

    test('a payload smaller than one chunk round trips in a single frame', () {
      final data = Uint8List.fromList(utf8.encode('hi'));
      final frames = dataToFrames(data);

      expect(frames.length, 1);
      expect(decodeFrames(frames), data);
    });

    test('a payload exactly filling its chunks round trips', () {
      // 80 + 20 wrapper = 100, an exact multiple of dataSize with no padding.
      final data = Uint8List.fromList(utf8.encode('e' * 80));
      final frames = dataToFrames(data, dataSize: 20);

      expect(frames.length, 5);
      expect(decodeFrames(frames), data);
    });

    test('an empty payload round trips to empty', () {
      final frames = dataToFrames('');

      expect(frames.length, 1);
      expect(decodeFrames(frames), isEmpty);
    });

    test('a tiny dataSize round trips across many frames', () {
      final data = Uint8List.fromList(utf8.encode('many small frames'));
      final frames = dataToFrames(data, dataSize: 3);

      expect(frames.length, ((20 + data.length) / 3).ceil());
      expect(decodeFrames(frames), data);
    });

    test('each loop of a repeated animation decodes on its own', () {
      final data = Uint8List.fromList(utf8.encode('looping payload ' * 10));
      final frames = dataToFrames(data, loops: 2);
      final perLoop = frames.length ~/ 2;

      expect(decodeFrames(frames.sublist(0, perLoop)), data);
      expect(decodeFrames(frames.sublist(perLoop)), data);
    });

    test('a corrupted chunk fails the md5 check', () {
      // The wrapper hash is the only thing standing between a misread frame and
      // a bogus ecash string handed to the parser.
      final data = Uint8List.fromList(utf8.encode('tamper me ' * 20));
      final frames = dataToFrames(data);
      final target = parseDataFrame(frames[1]);
      final tampered = Uint8List.fromList(target.data);
      tampered[0] = tampered[0] ^ 0xFF;

      final session = QrLoopSession(
        nonce: target.nonce,
        totalFrames: target.totalFrames,
      );
      for (final frame in frames) {
        final parsed = parseDataFrame(frame);
        session.addDataFrame(
          parsed.frameIndex,
          parsed.frameIndex == 1 ? tampered : parsed.data,
        );
      }
      final merged = session.mergeChunks();
      final declaredLength =
          (merged[0] << 24) | (merged[1] << 16) | (merged[2] << 8) | merged[3];
      final payload = merged.sublist(20, 20 + declaredLength);

      expect(md5.convert(payload).bytes, isNot(merged.sublist(4, 20)));
    });
  });
}
