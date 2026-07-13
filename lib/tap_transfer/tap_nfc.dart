import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// The handshake payload exchanged over NFC: the receiver's ephemeral public key
/// plus the per-session BLE rendezvous service UUID.
class TapRendezvous {
  final Uint8List pubkey; // 33-byte compressed secp256k1 key
  final String uuid; // BLE rendezvous service UUID

  const TapRendezvous({required this.pubkey, required this.uuid});
}

/// NFC side of "tap to send" (Phase 3), Android only.
///
/// Receiver publishes the rendezvous over HCE (reusing the existing
/// `ecashapp/nfc_hce` channel, encoded as an `ecashtap:<base64url>` URI record).
/// Sender enters reader mode (`ecashapp/nfc_tap`) and, on tap, reads that URI and
/// decodes it back into a [TapRendezvous]. The pubkey only ever crosses this
/// proximity-authenticated channel — never BLE — which is what makes the
/// transfer MITM-safe.
class TapNfc {
  static const MethodChannel _hce = MethodChannel('ecashapp/nfc_hce');
  static const MethodChannel _reader = MethodChannel('ecashapp/nfc_tap');
  static const EventChannel _readerEvents = EventChannel(
    'ecashapp/nfc_tap/events',
  );

  static const int _version = 1;
  static const String _scheme = 'ecashtap:';
  static const int _rendezvousLen = 1 + 33 + 16; // version + pubkey + uuid

  /// Whether NFC + HCE is available (receiver publish path).
  static Future<bool> hceAvailable() async {
    try {
      return (await _hce.invokeMethod<bool>('isAvailable')) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Receiver: serve [rendezvous] over HCE until [stopPublish].
  static Future<void> publish(TapRendezvous rendezvous) =>
      _hce.invokeMethod('start', {'payload': _scheme + _encode(rendezvous)});

  static Future<void> stopPublish() => _hce.invokeMethod('stop');

  /// Sender: enter NFC reader mode. Reads arrive on [reads].
  static Future<void> startReader() => _reader.invokeMethod('startReader');

  static Future<void> stopReader() => _reader.invokeMethod('stopReader');

  /// Sender: rendezvous decoded from a tapped receiver. Malformed reads are
  /// dropped rather than surfaced.
  static Stream<TapRendezvous> reads() =>
      _readerEvents
          .receiveBroadcastStream()
          .map((e) => _parseEvent(e as Map))
          .where((r) => r != null)
          .cast<TapRendezvous>();

  /// A fresh random rendezvous UUID for one transfer.
  static String randomUuid() {
    final rng = Random.secure();
    final b = Uint8List.fromList(
      List<int>.generate(16, (_) => rng.nextInt(256)),
    );
    b[6] = (b[6] & 0x0f) | 0x40; // version 4
    b[8] = (b[8] & 0x3f) | 0x80; // variant
    return _bytesToUuid(b);
  }

  static TapRendezvous? _parseEvent(Map map) {
    if (map['event'] != 'read') return null;
    final uri = map['uri'] as String?;
    if (uri == null || !uri.startsWith(_scheme)) return null;
    return _decode(uri.substring(_scheme.length));
  }

  static String _encode(TapRendezvous r) {
    final out = BytesBuilder();
    out.addByte(_version);
    out.add(r.pubkey);
    out.add(_uuidToBytes(r.uuid));
    return base64Url.encode(out.toBytes()).replaceAll('=', '');
  }

  static TapRendezvous? _decode(String b64) {
    try {
      final bytes = base64Url.decode(base64Url.normalize(b64));
      if (bytes.length != _rendezvousLen || bytes[0] != _version) return null;
      return TapRendezvous(
        pubkey: Uint8List.fromList(bytes.sublist(1, 34)),
        uuid: _bytesToUuid(bytes.sublist(34, 50)),
      );
    } catch (_) {
      return null;
    }
  }

  static Uint8List _uuidToBytes(String uuid) {
    final hex = uuid.replaceAll('-', '');
    final bytes = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }

  static String _bytesToUuid(List<int> b) {
    final hex = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20, 32)}';
  }
}
