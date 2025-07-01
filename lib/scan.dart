import 'dart:convert';

import 'package:carbine/fed_preview.dart';
import 'package:carbine/lib.dart';
import 'package:carbine/models.dart';
import 'package:carbine/multimint.dart';
import 'package:carbine/number_pad.dart';
import 'package:carbine/onchain_send.dart';
import 'package:carbine/pay_preview.dart';
import 'package:carbine/redeem_ecash.dart';
import 'package:carbine/theme.dart';
import 'package:carbine/utils.dart';
import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class ScanQRPage extends StatefulWidget {
  final FederationSelector? selectedFed;
  final PaymentType? paymentType;

  const ScanQRPage({super.key, this.selectedFed, this.paymentType});

  @override
  State<ScanQRPage> createState() => _ScanQRPageState();
}

class _ScanQRPageState extends State<ScanQRPage> {
  bool _scanned = false;
  bool _isPasting = false;
  _QrLoopSession? _currentSession;

  void _handleQrLoopChunk(String base64Str) {
    try {
      final bytes = base64Decode(base64Str);
      if (bytes.length < 5) return;

      final nonce = bytes[0];
      final totalFrames = (bytes[1] << 8) + bytes[2];
      final frameIndex = (bytes[3] << 8) + bytes[4];
      final chunkData = bytes.sublist(5);

      AppLogger.instance.info(
        "Frame $frameIndex / $totalFrames (nonce=$nonce)",
      );

      if (_currentSession == null || _currentSession!.nonce != nonce) {
        _currentSession = _QrLoopSession(
          nonce: nonce,
          totalFrames: totalFrames,
        );
      }

      final session = _currentSession!;

      if (!session.chunks.containsKey(frameIndex)) {
        session.chunks[frameIndex] = chunkData;
        setState(() {});
      }

      if (session.isComplete && !_scanned) {
        _scanned = true;
        final merged = session.mergeChunks();

        final lengthBytes = merged.sublist(0, 4);
        final declaredLength =
            (lengthBytes[0] << 24) |
            (lengthBytes[1] << 16) |
            (lengthBytes[2] << 8) |
            lengthBytes[3];

        final hashBytes = merged.sublist(4, 20);
        final payload = merged.sublist(20, 20 + declaredLength);

        final actualHash = md5.convert(payload).bytes;
        final isValid = const ListEquality().equals(actualHash, hashBytes);

        if (!isValid) {
          AppLogger.instance.warn("Expected hash: ${base64Encode(hashBytes)}");
          AppLogger.instance.warn("Actual hash:   ${base64Encode(actualHash)}");
          AppLogger.instance.warn("QR payload hash mismatch");
          return;
        }

        final actualPayload = utf8.decode(payload);
        AppLogger.instance.info("Decoded QR payload: $actualPayload");
        _handleText(actualPayload);
      }
    } catch (e) {
      AppLogger.instance.warn("Failed QR frame: $e");
      if (!_scanned) _onQRCodeScanned(base64Str);
    }
  }

  Future<void> _handleText(String text) async {
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
            final meta = await getFederationMeta(inviteCode: field0);
            final fed = await showCarbineModalBottomSheet(
              context: context,
              child: FederationPreview(
                federationName: meta.selector.federationName,
                inviteCode: meta.selector.inviteCode,
                welcomeMessage: meta.welcome,
                imageUrl: meta.picture,
                joinable: true,
                guardians: meta.guardians,
                network: meta.selector.network!,
              ),
            );
            if (fed != null) {
              await Future.delayed(const Duration(milliseconds: 400));
              Navigator.pop(context, fed);
            }
          }
          break;
        case ParsedText_LightningInvoice(:final field0):
          if (widget.paymentType == null ||
              widget.paymentType! == PaymentType.lightning) {
            final preview = await paymentPreview(
              federationId: chosenFederation!.federationId,
              bolt11: field0,
            );
            showCarbineModalBottomSheet(
              context: context,
              child: PaymentPreviewWidget(
                fed: chosenFederation,
                paymentPreview: preview,
              ),
            );
          }
          break;
        case ParsedText_BitcoinAddress(:final field0, :final field1):
          if (widget.paymentType == null ||
              widget.paymentType! == PaymentType.onchain) {
            if (field1 != null) {
              showCarbineModalBottomSheet(
                context: context,
                child: OnchainSend(
                  fed: chosenFederation!,
                  amountSats: field1.toSats,
                  withdrawalMode: WithdrawalMode.specificAmount,
                  defaultAddress: field0,
                ),
              );
            } else {
              final btcPrice = await fetchBtcPrice();
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder:
                      (_) => NumberPad(
                        fed: chosenFederation!,
                        paymentType: PaymentType.onchain,
                        btcPrice: btcPrice,
                        onWithdrawCompleted: null,
                        bitcoinAddress: field0,
                      ),
                ),
              );
            }
          }
          break;
        case ParsedText_Ecash(:final field0):
          if (widget.paymentType == null ||
              widget.paymentType! == PaymentType.ecash) {
            showCarbineModalBottomSheet(
              context: context,
              child: EcashRedeemPrompt(
                fed: chosenFederation!,
                ecash: text,
                amount: field0,
              ),
              heightFactor: 0.33,
            );
          }
          break;
      }
    } catch (e) {
      AppLogger.instance.warn("No action for scanned text: $text");
    }
  }

  void _onQRCodeScanned(String code) async {
    if (_scanned) return;
    _scanned = true;
    await _handleText(code);
  }

  Future<void> _pasteFromClipboard() async {
    setState(() => _isPasting = true);
    final clipboardData = await Clipboard.getData('text/plain');
    final text = clipboardData?.text ?? '';

    if (text.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("Clipboard is empty")));
      setState(() => _isPasting = false);
      return;
    }

    await _handleText(text);
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
          title: const Text(
            'Scan QR',
            style: TextStyle(fontWeight: FontWeight.bold),
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
              child: MobileScanner(
                onDetect: (capture) {
                  final barcode = capture.barcodes.first;
                  final String? code = barcode.rawValue;
                  if (code != null) _handleQrLoopChunk(code);
                },
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
                              valueColor: const AlwaysStoppedAnimation<Color>(
                                Colors.greenAccent,
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
                    _isPasting ? "Pasting..." : "Paste from Clipboard",
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

class _QrLoopSession {
  final int nonce;
  final int totalFrames;
  final Map<int, Uint8List> chunks = {};
  _QrLoopSession({required this.nonce, required this.totalFrames});

  bool get isComplete => chunks.length >= totalFrames;

  Uint8List mergeChunks() {
    final List<int> fullData = [];
    for (int i = 0; i < totalFrames; i++) {
      fullData.addAll(chunks[i]!);
    }
    return Uint8List.fromList(fullData);
  }
}
