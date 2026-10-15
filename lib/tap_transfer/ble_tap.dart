import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// BLE permissions both roles need: the sender advertises and serves GATT, the
/// receiver scans and connects.
const _blePermissions = [
  Permission.bluetoothScan,
  Permission.bluetoothConnect,
  Permission.bluetoothAdvertise,
];

/// An event streamed from the native BLE tap-transfer controller.
///
/// `event` is one of: `status`, `received`, `error`.
///  - `status`  → [state] set (advertising/scanning/connecting/connected/writing/sent/confirmed/stopped)
///  - `received`→ [data] is the fully reassembled encrypted blob (receiver side)
///  - `error`   → [message] set
class BleTapEvent {
  final String event;
  final String? state;
  final String? message;
  final Uint8List? data;

  const BleTapEvent({required this.event, this.state, this.message, this.data});

  factory BleTapEvent.fromMap(Map<dynamic, dynamic> map) => BleTapEvent(
    event: map['event'] as String,
    state: map['state'] as String?,
    message: map['message'] as String?,
    data: map['data'] as Uint8List?,
  );

  @override
  String toString() =>
      'BleTapEvent($event${state != null ? ' $state' : ''}'
      '${message != null ? ' "$message"' : ''}'
      '${data != null ? ' ${data!.length}B' : ''})';
}

/// Thin Dart wrapper over the native `ecashapp/ble_tap` channels (Android 12+).
/// Check [isSupported] before enabling either role. Older devices can still
/// use the wallet and QR transfers.
///
/// See android/app/src/main/kotlin/app/ecash/BleTapController.kt. This is the
/// Phase 2 transport: it moves an already-encrypted blob between two phones over
/// a no-bond GATT connection. Encryption/decryption itself lives in Rust
/// (`TapRecipient` / `encryptEcashForTap`).
class BleTap {
  static const MethodChannel _method = MethodChannel('ecashapp/ble_tap');
  static const EventChannel _events = EventChannel('ecashapp/ble_tap/events');

  static Future<bool> isSupported() async {
    if (!Platform.isAndroid) return false;
    return (await _method.invokeMethod<bool>('isSupported')) ?? false;
  }

  /// Broadcast stream of controller events. Safe to listen to before starting.
  static Stream<BleTapEvent> events() => _events.receiveBroadcastStream().map(
    (e) => BleTapEvent.fromMap(e as Map<dynamic, dynamic>),
  );

  /// Whether BLE is present and enabled on this device. Always false off
  /// Android.
  static Future<bool> isAvailable() async {
    if (!await isSupported()) return false;
    return (await _method.invokeMethod<bool>('isAvailable')) ?? false;
  }

  static Future<bool> permissionsGranted() async {
    if (!await isSupported()) return false;
    for (final p in _blePermissions) {
      if (!await p.isGranted) return false;
    }
    return true;
  }

  static Future<bool> requestPermissions() async {
    if (!await isSupported()) return false;
    final statuses = await _blePermissions.request();
    return statuses.values.every((s) => s.isGranted);
  }

  /// Sender: advertise the per-session rendezvous [serviceUuid] (learned over
  /// NFC) and push [blob] — already encrypted for the pubkey that came with it —
  /// to the first central that connects.
  ///
  /// The sender is the peripheral because Android 17's GATT *client* accepts
  /// attribute writes and never delivers their callback, so the payload travels
  /// as server-to-client notifications instead. See BleTapController.kt.
  static Future<void> startSending(String serviceUuid, Uint8List blob) =>
      _method.invokeMethod<void>('startSending', {
        'uuid': serviceUuid,
        'blob': blob,
      });

  /// Receiver: scan for [serviceUuid], connect (no bond), and collect the pushed
  /// blob, which arrives as a `received` event.
  static Future<void> startReceiving(String serviceUuid) =>
      _method.invokeMethod<void>('startReceiving', {'uuid': serviceUuid});

  /// Tear down whichever role is active and release BLE resources.
  static Future<void> stop() => _method.invokeMethod<void>('stop');

  /// Wait for a completed transfer's disconnect/linger before releasing BLE.
  /// An incomplete transfer is cancelled immediately.
  static Future<void> finish() => _method.invokeMethod<void>('finish');
}
