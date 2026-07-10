import 'dart:async';

import 'package:flutter/services.dart';

/// An event streamed from the native BLE tap-transfer controller.
///
/// `event` is one of: `status`, `pubkey`, `received`, `error`.
///  - `status`  → [state] set (advertising/scanning/connecting/connected/writing/sent/confirmed/stopped)
///  - `pubkey`  → [data] is the receiver's 33-byte ephemeral public key (sender side)
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

/// Thin Dart wrapper over the native `ecashapp/ble_tap` channels (Android only).
///
/// See android/app/src/main/kotlin/app/ecash/BleTapController.kt. This is the
/// Phase 2 transport: it moves an already-encrypted blob between two phones over
/// a no-bond GATT connection. Encryption/decryption itself lives in Rust
/// (`TapRecipient` / `encryptEcashForTap`).
class BleTap {
  static const MethodChannel _method = MethodChannel('ecashapp/ble_tap');
  static const EventChannel _events = EventChannel('ecashapp/ble_tap/events');

  /// Broadcast stream of controller events. Safe to listen to before starting.
  static Stream<BleTapEvent> events() => _events.receiveBroadcastStream().map(
    (e) => BleTapEvent.fromMap(e as Map<dynamic, dynamic>),
  );

  /// Whether BLE is present and enabled on this device.
  static Future<bool> isAvailable() async =>
      (await _method.invokeMethod<bool>('isAvailable')) ?? false;

  /// Receiver: advertise the rendezvous service and serve [pubkey] to senders.
  static Future<void> startReceiver(Uint8List pubkey) =>
      _method.invokeMethod<void>('startReceiver', {'pubkey': pubkey});

  /// Sender: scan for a receiver, connect, and read its pubkey (emitted as a
  /// `pubkey` event). Call [sendBlob] once you've encrypted for that pubkey.
  static Future<void> startSender() =>
      _method.invokeMethod<void>('startSender');

  /// Sender: stream an encrypted blob to the connected receiver.
  static Future<void> sendBlob(Uint8List blob) =>
      _method.invokeMethod<void>('sendBlob', {'blob': blob});

  /// Tear down whichever role is active and release BLE resources.
  static Future<void> stop() => _method.invokeMethod<void>('stop');
}
