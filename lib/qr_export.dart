import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

const int MAX_NONCE = 256;

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

Uint8List wrapData(Uint8List data) {
  final lengthBuffer = _uint32ToBytes(data.length);
  final hash = md5.convert(data).bytes;
  return Uint8List.fromList([...lengthBuffer, ...hash, ...data]);
}

List<String> makeLoop(
  Uint8List wrappedData,
  int dataSize,
  int index,
  double Function() random,
) {
  final nonce = index % MAX_NONCE;
  final dataChunks = cutAndPad(wrappedData, dataSize);
  final result = <String>[];

  for (int i = 0; i < dataChunks.length; i++) {
    result.add(
      makeDataFrame(
        data: dataChunks[i],
        nonce: nonce,
        totalFrames: dataChunks.length,
        frameIndex: i,
      ),
    );
  }

  return result;
}

List<String> dataToFrames(
  dynamic dataOrStr, {
  int dataSize = 100,
  int loops = 1,
}) {
  int seed = 1;
  double random() {
    final x = sin(seed++) * 10000;
    return x - x.floorToDouble();
  }

  final data =
      (dataOrStr is String) ? utf8.encode(dataOrStr) : dataOrStr as Uint8List;
  final wrappedData = wrapData(Uint8List.fromList(data));

  List<String> r = [];
  for (int i = 0; i < loops; i++) {
    r.addAll(makeLoop(wrappedData, dataSize, i, random));
  }
  return r;
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
