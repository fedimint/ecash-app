import 'dart:async';

import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/nfc_hce.dart';
import 'package:ecashapp/redeem_ecash.dart';
import 'package:ecashapp/screens/federation_info_screen.dart';
import 'package:ecashapp/tap_transfer/ble_tap.dart';
import 'package:ecashapp/tap_transfer/tap_nfc.dart';
import 'package:ecashapp/tap_transfer.dart';
import 'package:ecashapp/theme.dart';
import 'package:ecashapp/toast.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';

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
  StreamSubscription<void>? _tagSub;
  bool _armed = false;
  int _pauseCount = 0;

  /// UUID of the rendezvous currently published over NFC.
  String? _uuid;

  /// Whether a scan for the sender's advertisement is already in flight, so a
  /// tag read arriving twice for one tap doesn't restart it.
  bool _scanning = false;

  bool get _paused => _pauseCount > 0;

  /// Arm if possible. No-op if already armed, paused, unsupported, or if BLE
  /// permissions aren't already granted — we never prompt from here, so the
  /// feature switches on silently once the user has granted them (e.g. via a
  /// tap-send).
  Future<void> arm() async {
    if (_armed || _paused || !tapTransferSupported) return;
    try {
      if (!await getTapReceiveEnabled()) return;
      if (!await BleTap.isAvailable()) return;
      if (!await InvoiceNfcBroadcaster.isAvailable()) return;
      if (!await BleTap.permissionsGranted()) return;
      _armed = true;
      _sub ??= BleTap.events().listen(
        _onEvent,
        onError: (e) => AppLogger.instance.warn("tap receive stream: $e"),
      );
      _tagSub ??= TapNfc.tagReads().listen(
        (_) => _onTagRead(),
        onError: (e) => AppLogger.instance.warn("tap receive hce stream: $e"),
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
      await _tagSub?.cancel();
      _tagSub = null;
      await TapNfc.stopPublish();
      await BleTap.stop();
    } catch (e) {
      AppLogger.instance.warn("tap receive: disarm error: $e");
    }
    _recipient?.dispose();
    _recipient = null;
    _uuid = null;
    _scanning = false;
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
    _uuid = uuid;
    _scanning = false;
    await BleTap.stop();
    await TapNfc.publish(
      TapRendezvous(pubkey: recipient.publicKey(), uuid: uuid),
    );
    // No BLE yet: the sender is the peripheral now, so there is nothing to scan
    // for until it has read this rendezvous and started advertising it. That
    // moment arrives as a tag read - see [_onTagRead].
  }

  /// A reader just pulled our rendezvous off the NFC tag, so the sender is about
  /// to advertise it. Start scanning for it.
  Future<void> _onTagRead() async {
    if (!_armed || _paused || _scanning) return;
    final uuid = _uuid;
    if (uuid == null) return;
    _scanning = true;
    AppLogger.instance.info("tap receive: tag read, scanning for sender");
    try {
      await BleTap.startReceiving(uuid);
    } catch (e) {
      _scanning = false;
      AppLogger.instance.warn("tap receive: could not start scan: $e");
    }
  }

  void _onEvent(BleTapEvent e) {
    if (e.event == 'error') {
      // Previously dropped, which made every transport failure look like silence.
      _scanning = false;
      AppLogger.instance.warn("tap receive: ${e.message}");
      return;
    }
    if (e.event != 'received' || e.data == null) return;
    _scanning = false;
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
    AppLogger.instance.info("tap receive: decrypted a token, presenting");
    onEcash?.call(ecash);
    // Fresh rendezvous + key for the next transfer.
    _rotate();
  }
}

/// Route a received ecash string through the same path the QR scanner uses: the
/// redeem bottom sheet for a known federation, the join flow for an invite-code
/// ecash, or an error for ecash with no resolvable federation.
///
/// Returns the federation joined (and whether it is recovering) when the ecash
/// came with an invite code and the user joined, so the caller can select it.
Future<(FederationSelector, bool)?> presentReceivedEcash(
  BuildContext context,
  String ecash,
) async {
  try {
    final (action, fed) = await parsedScannedText(text: ecash);
    if (!context.mounted) return null;
    switch (action) {
      case ParsedText_Ecash(:final field0):
        if (fed == null) return null;
        await showAppModalBottomSheet(
          context: context,
          childBuilder:
              () async =>
                  EcashRedeemPrompt(fed: fed, ecash: ecash, amount: field0),
          fitContent: true,
        );
        break;
      case ParsedText_InviteCodeWithEcash(:final field0, :final field1):
        // The preview downloads the federation's metadata itself, like the
        // scanner's join flow.
        return Navigator.push<(FederationSelector, bool)>(
          context,
          MaterialPageRoute(
            builder:
                (_) => FederationInfoScreen(
                  inviteCode: field0,
                  joinable: true,
                  ecash: field1,
                  onLeaveFederation: () {},
                ),
          ),
        );
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
  return null;
}
