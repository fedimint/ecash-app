import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

/// Byte 0 of every data frame, identifying the transfer to the scanner.
///
/// Fixed for the life of a payload. The scanner reads a change of nonce as a
/// new transfer and, while frames are still arriving, refuses to hand over
/// (see the takeover guard in `_handleQrLoopChunk`) — so renumbering between
/// repeats would get every later frame dropped rather than giving a missed one
/// a second chance. The animation replays these same frames instead.
///
/// 100 is not available here: `_ScanState.FOUNTAIN_V1_CONST` claims that value
/// as a format marker, and the scanner dispatches on this byte before it knows
/// which kind of frame it is holding.
const int _frameNonce = 0;

List<Uint8List> cutAndPad(Uint8List data, int size) {
  final numChunks = (data.length / size).ceil();
  final List<Uint8List> chunks = List.generate(numChunks, (i) {
    final start = i * size;
    final end = (start + size > data.length) ? data.length : start + size;
    return Uint8List.fromList(data.sublist(start, end));
  });

  // Pad last chunk if necessary
  final last = numChunks - 1;
  final pad = size - chunks[last].length;
  if (pad > 0) {
    final padded = Uint8List(size);
    padded.setAll(0, chunks[last]);
    // remaining bytes are already zero-initialized
    chunks[last] = padded;
  }

  return chunks;
}

String makeDataFrame({
  required Uint8List data,
  required int nonce,
  required int totalFrames,
  required int frameIndex,
}) {
  final head = BytesBuilder();
  head.addByte(nonce);
  head.add(_uint16ToBytes(totalFrames));
  head.add(_uint16ToBytes(frameIndex));

  final combined = Uint8List.fromList([...head.toBytes(), ...data]);
  return base64Encode(combined);
}

/// Prefixes the payload with its length and an md5 digest.
///
/// The digest is error detection only — it catches a garbled or truncated
/// transfer, which is the job it is here to do. It is not an integrity
/// guarantee and must never be read as one: it travels inside the data it
/// covers, so anyone altering the payload simply recomputes it. Changing the
/// algorithm would not help; only a keyed MAC or a signature could, and that
/// needs a key the two devices have no way to share over a camera.
Uint8List wrapData(Uint8List data) {
  final lengthBuffer = _uint32ToBytes(data.length);
  final hash = md5.convert(data).bytes;
  return Uint8List.fromList([...lengthBuffer, ...hash, ...data]);
}

List<String> makeLoop(Uint8List wrappedData, int dataSize) {
  final dataChunks = cutAndPad(wrappedData, dataSize);
  final result = <String>[];

  for (int i = 0; i < dataChunks.length; i++) {
    result.add(
      makeDataFrame(
        data: dataChunks[i],
        nonce: _frameNonce,
        totalFrames: dataChunks.length,
        frameIndex: i,
      ),
    );
  }

  return result;
}

List<String> dataToFrames(dynamic dataOrStr, {int dataSize = 100}) {
  final data =
      (dataOrStr is String) ? utf8.encode(dataOrStr) : dataOrStr as Uint8List;
  final wrappedData = wrapData(Uint8List.fromList(data));
  return makeLoop(wrappedData, dataSize);
}

// --- Helper methods ---

Uint8List _uint16ToBytes(int value) {
  return Uint8List(2)
    ..[0] = (value >> 8) & 0xFF
    ..[1] = value & 0xFF;
}

Uint8List _uint32ToBytes(int value) {
  return Uint8List(4)
    ..[0] = (value >> 24) & 0xFF
    ..[1] = (value >> 16) & 0xFF
    ..[2] = (value >> 8) & 0xFF
    ..[3] = value & 0xFF;
}
