import 'dart:typed_data';

import 'package:ecashapp/utils.dart';

/// Reassembly state for the legacy base64 QR-loop transfer format.
///
/// Nothing in this app produces these frames — the only writers are other
/// wallets, or someone holding a hostile code up to the camera — so every
/// header field here is untrusted input. Lives apart from the scanner widget so
/// the bounds and index rules can be tested without a camera.

class FountainFramePending {
  final String idBase64; // used for dedupe
  final int version;
  final List<int> indexes;
  final Uint8List data;

  FountainFramePending(this.idBase64, this.version, this.indexes, this.data);

  FountainFrame toFountainFrame() => FountainFrame(version, indexes, data);
}

class FountainFrame {
  final int version;
  final List<int> indexes;
  final Uint8List data;

  FountainFrame(this.version, this.indexes, this.data);
}

class QrLoopSession {
  final int nonce;
  final int totalFrames;
  final Map<int, Uint8List> chunks = {};
  final List<FountainFrame> fountains = [];

  /// Cap on fountain frames held for one session. Fountains are only useful
  /// while chunks are still missing, and `_tryRecover` already discards spent
  /// ones — this bounds the case where none of them ever become usable.
  static const int _maxFountains = 256;

  /// When the last frame landed, used to decide whether a different nonce is
  /// allowed to take over. See `_sessionTakeoverIdle`.
  DateTime _lastFrameAt = DateTime.now();

  QrLoopSession({required this.nonce, required this.totalFrames});

  bool isIdleFor(Duration d) => DateTime.now().difference(_lastFrameAt) > d;

  /// Whether `index` is one this session is actually waiting for.
  ///
  /// Nothing upstream guarantees it: an out-of-range index used to be stored
  /// happily, which inflated `chunks.length` until [isComplete] reported a
  /// session that [mergeChunks] could not assemble. Keeping every key inside
  /// the range makes the count exact and the merge total.
  bool _isValidIndex(int index) => index >= 0 && index < totalFrames;

  bool get isComplete => chunks.length >= totalFrames;

  bool addDataFrame(int frameIndex, Uint8List data) {
    if (!_isValidIndex(frameIndex)) {
      AppLogger.instance.warn(
        "Ignoring frame $frameIndex outside 0..${totalFrames - 1}",
      );
      return false;
    }
    if (!chunks.containsKey(frameIndex)) {
      _lastFrameAt = DateTime.now();
      chunks[frameIndex] = data;
      _tryRecover();
      return true;
    }
    _lastFrameAt = DateTime.now();
    return false;
  }

  void addFountainFrame(FountainFrame f) {
    // A fountain recovers whichever of its indexes is missing, writing straight
    // into `chunks` — so an out-of-range index here would reintroduce exactly
    // the mismatch `_isValidIndex` exists to prevent.
    if (!f.indexes.every(_isValidIndex)) {
      AppLogger.instance.warn(
        "Ignoring fountain with out-of-range indexes ${f.indexes}",
      );
      return;
    }
    if (fountains.length >= _maxFountains) {
      fountains.removeAt(0);
    }
    fountains.add(f);
    _tryRecover();
  }

  void _tryRecover() {
    bool progress = true;
    while (progress) {
      progress = false;

      for (int i = 0; i < fountains.length;) {
        final f = fountains[i];

        // which indexes are missing
        final missing =
            f.indexes.where((idx) => !chunks.containsKey(idx)).toList();

        // collect known frames' data for the indexes present
        final existingFramesData = <Uint8List>[];
        for (final idx in f.indexes) {
          final known = chunks[idx];
          if (known != null) existingFramesData.add(known);
        }

        if (existingFramesData.isNotEmpty) {
          // compute min length among known frames
          final minKnownLen = existingFramesData
              .map((d) => d.length)
              .reduce((a, b) => a < b ? a : b);

          // If fountain length does not match min known length, drop the fountain (incompatible).
          if (f.data.length != minKnownLen) {
            AppLogger.instance.info(
              "Dropping fountain: incompatible length (f.len=${f.data.length} minKnownLen=$minKnownLen)",
            );
            fountains.removeAt(i);
            continue;
          }
        }

        if (missing.isEmpty) {
          // fountain is useless now, remove it
          fountains.removeAt(i);
          continue;
        } else if (missing.length == 1) {
          // we can recover that missing chunk
          final int missingIndex = missing.first;

          // start with fountain data as Uint8List; we will XOR known frames into it
          // produce result length = f.data.length (should equal min known length per above)
          Uint8List recovered = Uint8List.fromList(f.data);

          // XOR existing frames (only up to recovered.length, because we've validated lengths)
          for (final idx in f.indexes) {
            if (idx == missingIndex) continue;
            final known = chunks[idx]!;
            // XOR only up to recovered.length
            for (int j = 0; j < recovered.length; j++) {
              recovered[j] = recovered[j] ^ known[j];
            }
          }

          // store recovered chunk
          chunks[missingIndex] = recovered;
          AppLogger.instance.info(
            "Recovered missing chunk $missingIndex from fountain (now have ${chunks.length}/$totalFrames)",
          );

          // remove fountain and restart loop (some fountains may now be usable)
          fountains.removeAt(i);
          progress = true;
          // restart scanning fountains from beginning
          i = 0;
          continue;
        } else {
          // cannot do anything for this fountain yet
          i++;
        }
      } // end for fountains
    } // end while progress
  }

  Uint8List mergeChunks() {
    final List<int> fullData = [];
    for (int i = 0; i < totalFrames; i++) {
      final c = chunks[i];
      if (c == null) {
        throw Exception(
          "Missing chunk $i during merge (have ${chunks.keys.toList()})",
        );
      }
      fullData.addAll(c);
    }
    return Uint8List.fromList(fullData);
  }
}
