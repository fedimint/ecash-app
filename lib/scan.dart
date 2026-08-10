import 'dart:convert';
import 'dart:io';

import 'package:ecashapp/app.dart';
import 'package:ecashapp/fountain.dart';
import 'package:ecashapp/screens/federation_info_screen.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/models.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/number_pad.dart';
import 'package:ecashapp/onchain_send.dart';
import 'package:ecashapp/pay_preview.dart';
import 'package:ecashapp/qr_loop_session.dart';
import 'package:ecashapp/redeem_ecash.dart';
import 'package:ecashapp/theme.dart';
import 'package:ecashapp/toast.dart';
import 'package:ecashapp/utils.dart';
import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_code_scanner_plus/qr_code_scanner_plus.dart';

class ScanQRPage extends StatefulWidget {
  final FederationSelector? selectedFed;
  final PaymentType? paymentType;
  final void Function(FederationSelector fed, bool recovering) onPay;
  final bool interceptMode;

  const ScanQRPage({
    super.key,
    this.selectedFed,
    this.paymentType,
    required this.onPay,
    this.interceptMode = false,
  });

  @override
  State<ScanQRPage> createState() => _ScanQRPageState();
}

class _ScanQRPageState extends State<ScanQRPage> {
  bool _scanned = false;
  bool _isPasting = false;
  bool _permissionDenied = false;
  QrLoopSession? _currentSession;

  final GlobalKey qrKey = GlobalKey(debugLabel: 'QR');
  QRViewController? _qrController;

  final List<FountainFramePending> _pendingFountains = [];
  final Set<String> _exploredFountains = {};
  static const int FOUNTAIN_V1_CONST = 100;

  // Everything below arrives from a camera, and nothing in this app produces
  // the legacy frame format — the only writer is some other wallet, or someone
  // holding up a hostile code. So the frame header is treated as untrusted
  // input: bounded, validated, and never trusted to describe itself honestly.

  /// Largest frame count a session will accept.
  ///
  /// The wire format allows 65535, which at realistic chunk sizes would let one
  /// crafted header reserve hundreds of megabytes. A real transfer is a QR loop
  /// someone physically holds up to a camera; 4096 frames is already far longer
  /// than anyone would stand there for.
  static const int _maxTotalFrames = 4096;

  /// Caps on the dedup set and the queue of fountain frames held for a session
  /// that has not started yet. Both are fed directly by frames on screen, so
  /// without a ceiling a loop of distinct frames grows them until the app dies.
  static const int _maxExploredFountains = 512;
  static const int _maxPendingFountains = 128;

  /// How long a session must go without a frame before a different nonce is
  /// allowed to replace it. Short enough that scanning a second code after
  /// glancing away still works; long enough that a code flashed at the camera
  /// mid-transfer cannot discard what has been collected.
  static const Duration _sessionTakeoverIdle = Duration(seconds: 5);

  static const String _fedimintFountainPrefix = 'fedimint';
  OobNotesDecoder _fountainDecoder = OobNotesDecoder();
  int _fountainFragmentsReceived = 0;

  @override
  void initState() {
    super.initState();
    _requestCameraPermission();
  }

  Future<void> _requestCameraPermission() async {
    // Skip permission check on desktop platforms where it's not supported
    if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
      return;
    }
    final status = await Permission.camera.status;
    if (!status.isGranted) {
      final result = await Permission.camera.request();
      if (!result.isGranted) {
        setState(() => _permissionDenied = true);
      }
    }
  }

  // Required for hot reload to work properly with qr_code_scanner_plus
  @override
  void reassemble() {
    super.reassemble();
    if (Platform.isAndroid) {
      _qrController?.pauseCamera();
    }
    _qrController?.resumeCamera();
  }

  @override
  void dispose() {
    _qrController?.dispose();
    super.dispose();
  }

  void _onQRViewCreated(QRViewController controller) {
    _qrController = controller;
    controller.scannedDataStream.listen((scanData) {
      if (scanData.code != null && scanData.code!.isNotEmpty) {
        _handleQrLoopChunk(scanData.code!);
      }
    });
  }

  void _handleQrLoopChunk(String base64Str) async {
    if (_scanned) return;
    try {
      // Fedimint fountain fragment path (new optimized QR format).
      // These base32 fragments are incompatible with the legacy base64 parser,
      // so intercept them before the rest of the pipeline runs.
      if (base64Str.startsWith(_fedimintFountainPrefix)) {
        // Drop any legacy-session state left from prior frames so the
        // progress bar doesn't stick around while we reassemble a fountain.
        if (_currentSession != null || _pendingFountains.isNotEmpty) {
          setState(() {
            _currentSession = null;
            _pendingFountains.clear();
            _exploredFountains.clear();
          });
        }

        final wrapper = _fountainDecoder.addFragment(fragment: base64Str);
        setState(() {
          _fountainFragmentsReceived++;
        });
        if (wrapper != null) {
          AppLogger.instance.info(
            "Fedimint fountain decode complete — reassembled ecash notes",
          );
          setState(() {
            _scanned = true;
            _fountainFragmentsReceived = 0;
          });
          _fountainDecoder = OobNotesDecoder();
          final parsed = await _handleText(wrapper.toString());
          if (!parsed) {
            ToastService().show(
              message: context.l10n.cannotBeParsed,
              duration: const Duration(seconds: 5),
              onTap: () {},
              icon: Icon(Icons.error),
            );
          }
          _resetScannedAfterDelay();
        }
        return;
      }

      AppLogger.instance.info(
        "Non-fountain QR frame (len=${base64Str.length}, head='${base64Str.substring(0, base64Str.length < 16 ? base64Str.length : 16)}')",
      );

      // If there is no current session, first try to just normally parse the text
      if (_currentSession == null) {
        setState(() {
          _scanned = true;
        });
        AppLogger.instance.info("Trying for first time to parse as non ecash");
        final parsed = await _handleText(base64Str);
        if (parsed) {
          _resetScannedAfterDelay();
          return;
        }
        setState(() {
          _scanned = false;
        });
      }

      final bytes = base64Decode(base64Str);
      if (bytes.isEmpty) return;
      final firstByte = bytes[0];

      if (firstByte == FOUNTAIN_V1_CONST) {
        // Fountain frame
        // Deduplicate by base64 string to avoid reprocessing same fountain from QR loop
        if (_exploredFountains.contains(base64Str)) {
          AppLogger.instance.info("Duplicate fountain frame ignored");
          return;
        }
        // Oldest first: the set exists to suppress the repeats of a looping
        // animation, and those repeat close together, so the recent entries are
        // the ones still worth remembering.
        if (_exploredFountains.length >= _maxExploredFountains) {
          _exploredFountains.remove(_exploredFountains.first);
        }
        _exploredFountains.add(base64Str);

        // A truncated frame would otherwise index past the end of the buffer and
        // throw, which the outer catch turns into a bare-QR parse attempt on
        // binary junk.
        if (bytes.length < 3) return;
        final k = (bytes[1] << 8) | bytes[2];
        if (bytes.length < 3 + 2 * k) return;
        final indexes = <int>[];
        for (int j = 0; j < k; j++) {
          final idx = (bytes[3 + 2 * j] << 8) | bytes[4 + 2 * j];
          indexes.add(idx);
        }
        final data = bytes.sublist(3 + 2 * k);
        final fountainPending = FountainFramePending(
          base64Str,
          firstByte,
          indexes,
          Uint8List.fromList(data),
        );

        // If session exists, add it there; otherwise queue it for future sessions
        if (_currentSession == null) {
          AppLogger.instance.info(
            "Queueing fountain frame (no active session yet)",
          );
          if (_pendingFountains.length >= _maxPendingFountains) {
            _pendingFountains.removeAt(0);
          }
          _pendingFountains.add(fountainPending);
        } else {
          AppLogger.instance.info(
            "Adding fountain frame to current session (indexes=$indexes)",
          );
          _currentSession!.addFountainFrame(fountainPending.toFountainFrame());
        }
        return;
      } else {
        // Data Frame
        if (bytes.length < 5) return;
        final nonce = bytes[0];
        final totalFrames = (bytes[1] << 8) + bytes[2];
        final frameIndex = (bytes[3] << 8) + bytes[4];
        final chunkData = bytes.sublist(5);

        // A zero count completes the session on its first frame and merges to
        // nothing; an enormous one is a memory reservation, not a transfer.
        if (totalFrames < 1 || totalFrames > _maxTotalFrames) {
          AppLogger.instance.warn(
            "Ignoring frame with implausible totalFrames=$totalFrames",
          );
          return;
        }

        final existing = _currentSession;
        if (existing == null || existing.nonce != nonce) {
          // Switching sessions throws away everything collected so far, so a
          // code flashed at the camera mid-transfer would otherwise be enough to
          // destroy a nearly-complete scan. Let the running session finish, and
          // only hand over once it has stopped receiving frames.
          if (existing != null &&
              existing.chunks.isNotEmpty &&
              !existing.isIdleFor(_sessionTakeoverIdle)) {
            AppLogger.instance.warn(
              "Ignoring nonce $nonce: nonce ${existing.nonce} still in progress "
              "(${existing.chunks.length}/${existing.totalFrames})",
            );
            return;
          }

          AppLogger.instance.info(
            "Starting new session! Nonce: $nonce TotalFrames: $totalFrames",
          );
          _currentSession = QrLoopSession(
            nonce: nonce,
            totalFrames: totalFrames,
          );

          // move any pending fountains into the new session (they will be attempted)
          if (_pendingFountains.isNotEmpty) {
            AppLogger.instance.info(
              "Transferring ${_pendingFountains.length} pending fountains to session",
            );
            for (final pf in _pendingFountains) {
              _currentSession!.addFountainFrame(pf.toFountainFrame());
            }
            _pendingFountains.clear();
          }
        }

        final session = _currentSession!;
        if (session.addDataFrame(frameIndex, Uint8List.fromList(chunkData))) {
          setState(() {});
        }

        AppLogger.instance.info(
          "Frame $frameIndex / $totalFrames (nonce=$nonce) added. Session size=${session.chunks.length}",
        );

        if (session.isComplete && !_scanned) {
          AppLogger.instance.info("Session complete! Reassembling…");
          setState(() {
            _scanned = true;
          });
          final Uint8List merged;
          try {
            merged = session.mergeChunks();
          } catch (e) {
            // Index validation should make this unreachable. It is caught anyway
            // because the alternative is worse than a dropped transfer: the
            // throw would skip _resetScannedAfterDelay below, leaving _scanned
            // set forever and the scanner ignoring every subsequent frame.
            AppLogger.instance.warn("Discarding unmergeable session: $e");
            setState(() {
              _currentSession = null;
            });
            _resetScannedAfterDelay();
            return;
          }
          await _processMerged(merged);
          _resetScannedAfterDelay();
        }
      }
    } catch (e) {
      AppLogger.instance.warn("Failed QR frame: $e");
      if (!_scanned) _onQRCodeScanned(base64Str);
    }
  }

  void _resetScannedAfterDelay() {
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() {
          _scanned = false;
        });
      }
    });
  }

  Future<void> _processMerged(Uint8List merged) async {
    try {
      final lengthBytes = merged.sublist(0, 4);
      final declaredLength =
          (lengthBytes[0] << 24) |
          (lengthBytes[1] << 16) |
          (lengthBytes[2] << 8) |
          lengthBytes[3];
      AppLogger.instance.info("Declared length: $declaredLength");

      final hashBytes = merged.sublist(4, 20);
      final payload = merged.sublist(20, 20 + declaredLength);
      AppLogger.instance.info("Payload length: ${payload.length}");

      final actualHash = md5.convert(payload).bytes;
      final isValid = const ListEquality().equals(actualHash, hashBytes);

      if (!isValid) {
        AppLogger.instance.warn("QR payload hash mismatch");
        return;
      }

      AppLogger.instance.info("Passed isValid check. Decoding payload...");
      // The payload is never logged: a reassembled ecash token is a bearer
      // instrument, and this log is a plaintext file that outlives the transfer.
      final actualPayload = utf8.decode(payload);
      final parsed = await _handleText(actualPayload);
      if (!parsed) {
        ToastService().show(
          message: context.l10n.cannotBeParsed,
          duration: const Duration(seconds: 5),
          onTap: () {},
          icon: Icon(Icons.error),
        );
      }
    } catch (e) {
      AppLogger.instance.error("Error processing merged chunks: $e");
    }
  }

  Future<bool> _handleText(String text) async {
    text = text.trim();

    if (widget.interceptMode) {
      if (mounted) Navigator.pop(context, text);
      return true;
    }

    try {
      ParsedText action;
      FederationSelector? chosenFederation;
      if (widget.selectedFed != null) {
        final result = await parseScannedTextForFederation(
          text: text,
          federation: widget.selectedFed!,
        );
        action = result.$1;
        chosenFederation = result.$2;
      } else {
        final result = await parsedScannedText(text: text);
        action = result.$1;
        chosenFederation = result.$2;
      }

      switch (action) {
        case ParsedText_InviteCode(:final field0):
          if (widget.paymentType == null) {
            final overlay = OverlayEntry(
              builder:
                  (_) => Container(
                    color: Colors.black54,
                    child: const Center(child: CircularProgressIndicator()),
                  ),
            );
            try {
              Overlay.of(context).insert(overlay);
              final meta = await getFederationMeta(inviteCode: field0);
              overlay.remove();
              if (!context.mounted) return false;
              final fed = await Navigator.push(
                context,
                MaterialPageRoute(
                  builder:
                      (_) => FederationInfoScreen(
                        fed: meta.selector,
                        inviteCode: field0,
                        welcomeMessage: meta.welcome,
                        imageUrl: meta.picture,
                        joinable: true,
                        onLeaveFederation: () {},
                      ),
                ),
              );
              if (fed != null && context.mounted) {
                Navigator.pop(context, fed);
              }
            } catch (e) {
              overlay.remove();
              AppLogger.instance.warn(
                "Error when retrieving federation meta: $e",
              );
              ToastService().show(
                message: context.l10n.couldNotGetFederationMetadataScan,
                duration: const Duration(seconds: 5),
                onTap: () {},
                icon: Icon(Icons.error),
              );
            }
          }
          break;
        case ParsedText_LightningInvoice(:final field0):
          if (widget.paymentType == null ||
              widget.paymentType! == PaymentType.lightning) {
            try {
              await showAppModalBottomSheet(
                context: context,
                childBuilder: () async {
                  final preview = await paymentPreviewWithGateways(
                    federationId: chosenFederation!.federationId,
                    bolt11: field0,
                  );
                  final feds = await federations();

                  return PaymentPreviewWidget(
                    fed: chosenFederation,
                    previewData: preview,
                    federations: feds,
                  );
                },
              );

              widget.onPay(chosenFederation!, false);
            } catch (e) {
              AppLogger.instance.warn(
                "Error when retrieving payment preview: $e",
              );
              ToastService().show(
                message: context.l10n.couldNotGetLightningPaymentDetails,
                duration: const Duration(seconds: 5),
                onTap: () {},
                icon: Icon(Icons.error),
              );
            }
          }
          break;
        case ParsedText_BitcoinAddress(:final field0, :final field1):
          if (widget.paymentType == null ||
              widget.paymentType! == PaymentType.onchain) {
            if (field1 != null) {
              await showAppModalBottomSheet(
                context: context,
                childBuilder: () async {
                  return OnchainSend(
                    fed: chosenFederation!,
                    amountSats: field1.toSats,
                    withdrawalMode: WithdrawalMode.specificAmount,
                    defaultAddress: field0,
                  );
                },
              );
            } else {
              final btcPrices = await fetchAllBtcPrices();
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder:
                      (_) => NumberPad(
                        fed: chosenFederation!,
                        paymentType: PaymentType.onchain,
                        btcPrices: btcPrices,
                        onWithdrawCompleted: null,
                        bitcoinAddress: field0,
                      ),
                ),
              );
            }
            widget.onPay(chosenFederation!, false);
          }
          break;
        case ParsedText_Ecash(:final field0):
          if (widget.paymentType == null ||
              widget.paymentType! == PaymentType.ecash) {
            invoicePaidToastVisible.value = false;
            await showAppModalBottomSheet(
              context: context,
              childBuilder: () async {
                return EcashRedeemPrompt(
                  fed: chosenFederation!,
                  ecash: text,
                  amount: field0,
                );
              },
              heightFactor: 0.5,
            );
            invoicePaidToastVisible.value = true;
            widget.onPay(chosenFederation!, false);
          }
          break;
        case ParsedText_LightningAddressOrLnurl(:final field0):
          if (widget.paymentType == null ||
              widget.paymentType == PaymentType.lightning) {
            final btcPrices = await fetchAllBtcPrices();
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder:
                    (_) => NumberPad(
                      fed: chosenFederation!,
                      paymentType: PaymentType.lightning,
                      btcPrices: btcPrices,
                      onWithdrawCompleted: null,
                      lightningAddressOrLnurl: field0,
                    ),
              ),
            );
          }
          break;
        case ParsedText_InviteCodeWithEcash(:final field0, :final field1):
          if (widget.paymentType == null) {
            final overlay = OverlayEntry(
              builder:
                  (_) => Container(
                    color: Colors.black54,
                    child: const Center(child: CircularProgressIndicator()),
                  ),
            );
            try {
              Overlay.of(context).insert(overlay);
              final meta = await getFederationMeta(inviteCode: field0);
              overlay.remove();
              if (!context.mounted) return false;
              final fed = await Navigator.push(
                context,
                MaterialPageRoute(
                  builder:
                      (_) => FederationInfoScreen(
                        fed: meta.selector,
                        inviteCode: field0,
                        welcomeMessage: meta.welcome,
                        imageUrl: meta.picture,
                        joinable: true,
                        ecash: field1,
                        onLeaveFederation: () {},
                      ),
                ),
              );
              if (fed != null && context.mounted) {
                Navigator.pop(context, fed);
              }
            } catch (e) {
              overlay.remove();
              AppLogger.instance.warn(
                "Error when retrieving federation meta: $e",
              );
              ToastService().show(
                message: context.l10n.couldNotGetFederationMetadataScan,
                duration: const Duration(seconds: 5),
                onTap: () {},
                icon: Icon(Icons.error),
              );
            }
          }
          break;
        case ParsedText_LnurlWithdraw(:final field0):
          if (chosenFederation != null) {
            await openLnurlWithdraw(
              context: context,
              url: field0,
              fed: chosenFederation,
            );
          }
          break;
        case ParsedText_EcashNoFederation():
          ToastService().show(
            message: context.l10n.validEcashNoFederation,
            duration: const Duration(seconds: 5),
            onTap: () {},
            icon: Icon(Icons.error),
          );
          break;
      }

      _currentSession = null;

      return true;
    } catch (e) {
      if (e.toString().contains("sufficient balance")) {
        AppLogger.instance.warn("No federation with sufficient balance");
        ToastService().show(
          message: context.l10n.noSufficientBalance,
          duration: const Duration(seconds: 5),
          onTap: () {},
          icon: Icon(Icons.error),
        );

        setState(() {
          _scanned = false;
        });
        return true;
      }
    }

    return false;
  }

  void _onQRCodeScanned(String code) async {
    if (_scanned) return;
    setState(() {
      _scanned = true;
    });
    final parsed = await _handleText(code);
    if (!parsed) {
      // Only the length: an unparseable scan is often an ecash token, and the
      // content would be spendable by anyone who reads the log.
      AppLogger.instance.warn(
        "Scanned code could not be parsed (${code.length} chars)",
      );
      ToastService().show(
        message: context.l10n.cannotBeParsed,
        duration: const Duration(seconds: 5),
        onTap: () {},
        icon: Icon(Icons.error),
      );
    }
    _resetScannedAfterDelay();
  }

  Future<void> _pasteFromClipboard() async {
    setState(() => _isPasting = true);
    final clipboardData = await Clipboard.getData('text/plain');
    final text = clipboardData?.text ?? '';

    if (text.isEmpty) {
      ToastService().show(
        message: context.l10n.clipboardIsEmpty,
        duration: const Duration(seconds: 5),
        onTap: () {},
        icon: Icon(Icons.warning),
      );
      setState(() => _isPasting = false);
      return;
    }

    final parsed = await _handleText(text);
    if (!parsed) {
      // Never the clipboard contents. A user who copied their seed phrase and
      // then pasted here would otherwise write all 12 words to a plaintext file
      // — parse failure is the *expected* outcome for a mnemonic.
      AppLogger.instance.warn(
        "Pasted text could not be parsed (${text.length} chars)",
      );
      ToastService().show(
        message: context.l10n.cannotBeParsed,
        duration: const Duration(seconds: 5),
        onTap: () {},
        icon: Icon(Icons.error),
      );
    }
    setState(() => _isPasting = false);
  }

  double? get _progress {
    final session = _currentSession;
    if (session == null || session.totalFrames <= 1) return null;
    return session.chunks.length / session.totalFrames;
  }

  @override
  Widget build(BuildContext context) {
    final received = _currentSession?.chunks.length ?? 0;
    final total = _currentSession?.totalFrames ?? 0;

    return SafeArea(
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            context.l10n.scanQr,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          centerTitle: true,
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
        body: Stack(
          children: [
            Positioned.fill(
              child:
                  (_permissionDenied || Platform.isLinux || Platform.isMacOS)
                      ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(
                              Icons.camera_alt_outlined,
                              size: 64,
                              color: Colors.grey,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              (Platform.isLinux || Platform.isMacOS)
                                  ? context.l10n.cameraScanNotSupportedDesktop
                                  : context.l10n.cameraPermissionRequired,
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.grey),
                            ),
                            if (_permissionDenied &&
                                !Platform.isLinux &&
                                !Platform.isMacOS) ...[
                              const SizedBox(height: 16),
                              ElevatedButton(
                                onPressed: () async {
                                  await openAppSettings();
                                },
                                child: Text(context.l10n.openSettings),
                              ),
                            ],
                          ],
                        ),
                      )
                      : QRView(
                        key: qrKey,
                        onQRViewCreated: _onQRViewCreated,
                        overlay: QrScannerOverlayShape(
                          borderColor: Theme.of(context).colorScheme.primary,
                          borderRadius: 10,
                          borderLength: 30,
                          borderWidth: 10,
                          cutOutSize: 280,
                        ),
                      ),
            ),
            if (_progress != null)
              Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.all(32.0),
                  child: TweenAnimationBuilder<double>(
                    duration: const Duration(milliseconds: 300),
                    tween: Tween<double>(begin: 0, end: _progress!),
                    builder: (context, value, child) {
                      return Stack(
                        alignment: Alignment.center,
                        children: [
                          SizedBox(
                            width: 100,
                            height: 100,
                            child: CircularProgressIndicator(
                              value: value,
                              strokeWidth: 8,
                              backgroundColor: Colors.grey.shade800,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                Theme.of(context).colorScheme.primary,
                              ),
                            ),
                          ),
                          Text(
                            "$received / $total",
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              )
            else if (_fountainFragmentsReceived > 0)
              Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.all(32.0),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox(
                        width: 100,
                        height: 100,
                        child: CircularProgressIndicator(
                          strokeWidth: 8,
                          backgroundColor: Colors.grey.shade800,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ),
                      Text(
                        "$_fountainFragmentsReceived",
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: ElevatedButton.icon(
                  onPressed: _isPasting ? null : _pasteFromClipboard,
                  icon:
                      _isPasting
                          ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2.0,
                            ),
                          )
                          : const Icon(Icons.paste),
                  label: Text(
                    _isPasting
                        ? context.l10n.pasting
                        : context.l10n.pasteFromClipboard,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
