import 'dart:async';

import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/redeem_ecash.dart';
import 'package:ecashapp/screens/federation_info_screen.dart';
import 'package:ecashapp/tap_transfer/ble_tap.dart';
import 'package:ecashapp/tap_transfer/tap_nfc.dart';
import 'package:ecashapp/tap_transfer.dart';
import 'package:ecashapp/theme.dart';
import 'package:ecashapp/toast.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

/// App-global passive receiver for "tap to send" ecash (Phase 4b).
///
/// While armed — app foregrounded, BLE permissions already granted, and no
/// send/invoice screen holding NFC/BLE — it keeps a fresh rendezvous published
/// over NFC (HCE) and advertised over BLE, listening for an incoming encrypted
/// blob. On receipt it decrypts and hands the ecash string to [onEcash] (wired
/// in app.dart to the redeem bottom sheet). Nothing is auto-reissued.
///
/// Arm/disarm follow the app lifecycle; [pause]/[resume] are a nesting-safe way
/// for screens that need exclusive NFC/BLE (the send screen, the Lightning
/// invoice HCE) to temporarily take over.
class TapReceive {
  TapReceive._();
  static final TapReceive instance = TapReceive._();

  /// Invoked with the decrypted ecash string. Set by app.dart.
  void Function(String ecash)? onEcash;

  TapRecipient? _recipient;
  StreamSubscription<BleTapEvent>? _sub;
  bool _armed = false;
  int _pauseCount = 0;

  bool get _paused => _pauseCount > 0;

  /// Arm if possible. No-op if already armed, paused, unsupported, or if BLE
  /// permissions aren't already granted — we never prompt from here, so the
  /// feature switches on silently once the user has granted them (e.g. via a
  /// tap-send).
  Future<void> arm() async {
    if (_armed || _paused) return;
    try {
      if (!await getTapReceiveEnabled()) return;
      if (!await BleTap.isAvailable()) return;
      if (!await TapNfc.hceAvailable()) return;
      if (!await _permissionsGranted()) return;
      _armed = true;
      _sub ??= BleTap.events().listen(
        _onEvent,
        onError: (e) => AppLogger.instance.warn("tap receive stream: $e"),
      );
      await _rotate();
      AppLogger.instance.info("tap receive: armed");
    } catch (e) {
      _armed = false;
      AppLogger.instance.warn("tap receive: arm failed: $e");
    }
  }

  Future<void> disarm() async {
    if (!_armed) return;
    _armed = false;
    try {
      await _sub?.cancel();
      _sub = null;
      await TapNfc.stopPublish();
      await BleTap.stop();
    } catch (e) {
      AppLogger.instance.warn("tap receive: disarm error: $e");
    }
    _recipient?.dispose();
    _recipient = null;
    AppLogger.instance.info("tap receive: disarmed");
  }

  Future<void> pause() async {
    _pauseCount++;
    await disarm();
  }

  Future<void> resume() async {
    if (_pauseCount > 0) _pauseCount--;
    if (_pauseCount == 0) await arm();
  }

  Future<void> _rotate() async {
    _recipient?.dispose();
    final recipient = TapRecipient();
    _recipient = recipient;
    final uuid = TapNfc.randomUuid();
    await TapNfc.publish(
      TapRendezvous(pubkey: recipient.publicKey(), uuid: uuid),
    );
    await BleTap.startReceiver(uuid);
  }

  void _onEvent(BleTapEvent e) {
    AppLogger.instance.info("tap receive ble: $e");
    if (e.event != 'received' || e.data == null) return;
    final recipient = _recipient;
    if (recipient == null) return;
    String ecash;
    try {
      ecash = recipient.decrypt(blob: e.data!);
    } catch (err) {
      AppLogger.instance.warn("tap receive: decrypt failed: $err");
      _rotate();
      return;
    }
    onEcash?.call(ecash);
    // Fresh rendezvous + key for the next transfer.
    _rotate();
  }

  Future<bool> _permissionsGranted() async {
    final scan = await Permission.bluetoothScan.status;
    final connect = await Permission.bluetoothConnect.status;
    final advertise = await Permission.bluetoothAdvertise.status;
    return scan.isGranted && connect.isGranted && advertise.isGranted;
  }

  /// Prompt for the BLE permissions the receiver needs. Called from the Settings
  /// toggle (the one place we're allowed to prompt), not from [arm].
  Future<bool> requestPermissions() async {
    final statuses =
        await [
          Permission.bluetoothScan,
          Permission.bluetoothConnect,
          Permission.bluetoothAdvertise,
        ].request();
    return statuses.values.every((s) => s.isGranted);
  }
}

/// Route a received ecash string through the same path the QR scanner uses: the
/// redeem bottom sheet for a known federation, the join flow for an invite-code
/// ecash, or an error for ecash with no resolvable federation.
Future<void> presentReceivedEcash(BuildContext context, String ecash) async {
  try {
    final (action, fed) = await parsedScannedText(text: ecash);
    if (!context.mounted) return;
    switch (action) {
      case ParsedText_Ecash(:final field0):
        if (fed == null) return;
        await showAppModalBottomSheet(
          context: context,
          heightFactor: 0.5,
          childBuilder:
              () async =>
                  EcashRedeemPrompt(fed: fed, ecash: ecash, amount: field0),
        );
        break;
      case ParsedText_InviteCodeWithEcash(:final field0, :final field1):
        await _presentJoin(context, field0, field1);
        break;
      case ParsedText_EcashNoFederation():
        ToastService().show(
          message: context.l10n.validEcashNoFederation,
          duration: const Duration(seconds: 5),
          onTap: () {},
          icon: const Icon(Icons.error),
        );
        break;
      default:
        break;
    }
  } catch (e) {
    AppLogger.instance.warn("tap receive: could not present ecash: $e");
  }
}

Future<void> _presentJoin(
  BuildContext context,
  String inviteCode,
  String ecash,
) async {
  try {
    final meta = await getFederationMeta(inviteCode: inviteCode);
    if (!context.mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder:
            (_) => FederationInfoScreen(
              fed: meta.selector,
              inviteCode: inviteCode,
              welcomeMessage: meta.welcome,
              imageUrl: meta.picture,
              joinable: true,
              ecash: ecash,
              onLeaveFederation: () {},
            ),
      ),
    );
  } catch (e) {
    AppLogger.instance.warn("tap receive: federation meta failed: $e");
    if (context.mounted) {
      ToastService().show(
        message: context.l10n.couldNotGetFederationMetadataScan,
        duration: const Duration(seconds: 5),
        onTap: () {},
        icon: const Icon(Icons.error),
      );
    }
  }
}
