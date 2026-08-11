import 'dart:typed_data';

import 'package:ecashapp/qr_loop_session.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List bytes(List<int> b) => Uint8List.fromList(b);

void main() {
  group('QrLoopSession frame indexes', () {
    test('accepts an index inside the declared range', () {
      final session = QrLoopSession(nonce: 7, totalFrames: 3);

      expect(session.addDataFrame(0, bytes([1, 2])), isTrue);
      expect(session.chunks.keys, [0]);
    });

    test('rejects an index past the last frame', () {
      final session = QrLoopSession(nonce: 7, totalFrames: 3);

      expect(session.addDataFrame(3, bytes([1])), isFalse);
      expect(session.addDataFrame(500, bytes([1])), isFalse);
      expect(session.chunks, isEmpty);
    });

    test('rejects a negative index', () {
      final session = QrLoopSession(nonce: 7, totalFrames: 3);

      expect(session.addDataFrame(-1, bytes([1])), isFalse);
      expect(session.chunks, isEmpty);
    });

    test('a single out-of-range frame cannot complete a session', () {
      // The wedge: totalFrames=1 with frameIndex=500 used to store one chunk,
      // making `chunks.length >= totalFrames` true while chunk 0 was missing.
      // mergeChunks then threw from a path that had already set _scanned, so the
      // scanner stopped accepting frames entirely.
      final session = QrLoopSession(nonce: 1, totalFrames: 1);

      session.addDataFrame(500, bytes([9, 9, 9]));

      expect(session.isComplete, isFalse);
      expect(session.chunks, isEmpty);
    });

    test('a duplicate index does not count twice toward completion', () {
      final session = QrLoopSession(nonce: 7, totalFrames: 2);

      expect(session.addDataFrame(0, bytes([1])), isTrue);
      expect(session.addDataFrame(0, bytes([2])), isFalse);
      expect(session.isComplete, isFalse);
      expect(session.chunks[0], bytes([1]), reason: 'first write wins');
    });

    test('completing every index merges them in index order', () {
      final session = QrLoopSession(nonce: 7, totalFrames: 3);

      session.addDataFrame(2, bytes([5, 6]));
      session.addDataFrame(0, bytes([1, 2]));
      session.addDataFrame(1, bytes([3, 4]));

      expect(session.isComplete, isTrue);
      expect(session.mergeChunks(), bytes([1, 2, 3, 4, 5, 6]));
    });
  });

  group('QrLoopSession fountain frames', () {
    test('recovers a missing chunk by XOR', () {
      final session = QrLoopSession(nonce: 7, totalFrames: 2);
      session.addDataFrame(0, bytes([0x0F, 0xF0]));

      // Fountain over {0, 1} carrying chunk0 ^ chunk1.
      session.addFountainFrame(FountainFrame(1, [0, 1], bytes([0x35, 0x53])));

      expect(session.chunks[1], bytes([0x3A, 0xA3]));
      expect(session.isComplete, isTrue);
    });

    test('ignores a fountain naming an index outside the range', () {
      // Recovery writes straight into `chunks`, so an unchecked index here would
      // reintroduce the same length/merge mismatch as a bad data frame.
      final session = QrLoopSession(nonce: 7, totalFrames: 2);
      session.addDataFrame(0, bytes([0x0F, 0xF0]));

      session.addFountainFrame(FountainFrame(1, [0, 99], bytes([0x35, 0x53])));

      expect(session.chunks.keys, [0]);
      expect(session.fountains, isEmpty);
    });

    test('bounds how many unusable fountains it will hold', () {
      final session = QrLoopSession(nonce: 7, totalFrames: 400);

      // None of these can recover anything: each is missing two chunks.
      for (var i = 0; i < 400; i++) {
        session.addFountainFrame(FountainFrame(1, [0, 1], bytes([i % 256])));
      }

      expect(session.fountains.length, lessThanOrEqualTo(256));
    });
  });

  group('QrLoopSession takeover timing', () {
    test('a session that just received a frame is not idle', () {
      final session = QrLoopSession(nonce: 7, totalFrames: 2);
      session.addDataFrame(0, bytes([1]));

      expect(session.isIdleFor(const Duration(seconds: 5)), isFalse);
    });

    test('a repeated frame still counts as the session being alive', () {
      // A looping sender re-shows frames it has already sent. Those must keep
      // the session from looking idle, or a hostile nonce could take over
      // mid-loop simply by waiting out the window.
      final session = QrLoopSession(nonce: 7, totalFrames: 2);
      session.addDataFrame(0, bytes([1]));
      expect(session.addDataFrame(0, bytes([1])), isFalse);

      expect(session.isIdleFor(const Duration(seconds: 5)), isFalse);
    });
  });
}
