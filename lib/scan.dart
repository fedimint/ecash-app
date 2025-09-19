import 'dart:convert';

import 'package:ecashapp/app.dart';
import 'package:ecashapp/fed_preview.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/models.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/number_pad.dart';
import 'package:ecashapp/onchain_send.dart';
import 'package:ecashapp/pay_preview.dart';
import 'package:ecashapp/redeem_ecash.dart';
import 'package:ecashapp/theme.dart';
import 'package:ecashapp/toast.dart';
import 'package:ecashapp/utils.dart';
import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class ScanQRPage extends StatefulWidget {
  final FederationSelector? selectedFed;
  final PaymentType? paymentType;
  final void Function(FederationSelector fed, bool recovering) onPay;

  const ScanQRPage({
    super.key,
    this.selectedFed,
    this.paymentType,
    required this.onPay,
  });

  @override
  State<ScanQRPage> createState() => _ScanQRPageState();
}

class _ScanQRPageState extends State<ScanQRPage> {
  bool _scanned = false;
  bool _isPasting = false;
  _QrLoopSession? _currentSession;

  void _handleQrLoopChunk(String base64Str) async {
    if (_scanned) return;
    try {
      // If there is no current session, first try to just normally parse the text
      if (_currentSession == null) {
        // Set _scanned to try so we don't parse it multiple times
        setState(() {
          _scanned = true;
        });
        final parsed = await _handleText(base64Str);
        if (parsed) {
          return;
        } else {
          // If we cannot parse the text, fall through and try to parse as an animated QR code
          setState(() {
            _scanned = false;
          });
        }
      }

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
        final parsed = await _handleText(actualPayload);
        if (!parsed) {
          AppLogger.instance.warn("$actualPayload cannot be parsed");
          ToastService().show(
            message: "Sorry! That cannot be parsed.",
            duration: const Duration(seconds: 5),
            onTap: () {},
            icon: Icon(Icons.error),
          );
        }
      }
    } catch (e) {
      AppLogger.instance.warn("Failed QR frame: $e");
      if (!_scanned) _onQRCodeScanned(base64Str);
    }
  }

  Future<bool> _handleText(String text) async {
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
            try {
              final fed = await showAppModalBottomSheet(
                context: context,
                childBuilder: () async {
                  final meta = await getFederationMeta(inviteCode: field0);
                  return FederationPreview(
                    fed: meta.selector,
                    inviteCode: field0,
                    welcomeMessage: meta.welcome,
                    imageUrl: meta.picture,
                    joinable: true,
                    guardians: meta.guardians,
                  );
                },
              );
              if (fed != null) {
                await Future.delayed(const Duration(milliseconds: 400));
                Navigator.pop(context, fed);
              }
            } catch (e) {
              AppLogger.instance.warn(
                "Error when retrieving federation meta: $e",
              );
              ToastService().show(
                message: "Sorry! Could not get federation metadata",
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
                  final preview = await paymentPreview(
                    federationId: chosenFederation!.federationId,
                    bolt11: field0,
                  );

                  return PaymentPreviewWidget(
                    fed: chosenFederation,
                    paymentPreview: preview,
                  );
                },
              );

              widget.onPay(chosenFederation!, false);
            } catch (e) {
              AppLogger.instance.warn(
                "Error when retrieving payment preview: $e",
              );
              ToastService().show(
                message: "Sorry! Could not get Lightning payment details",
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
              heightFactor: 0.33,
            );
            invoicePaidToastVisible.value = true;
            widget.onPay(chosenFederation!, false);
          }
          break;
        case ParsedText_LightningAddressOrLnurl(:final field0):
          if (widget.paymentType == null ||
              widget.paymentType == PaymentType.lightning) {
            final btcPrice = await fetchBtcPrice();
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder:
                    (_) => NumberPad(
                      fed: chosenFederation!,
                      paymentType: PaymentType.lightning,
                      btcPrice: btcPrice,
                      onWithdrawCompleted: null,
                      lightningAddressOrLnurl: field0,
                    ),
              ),
            );
          }
          break;
      }

      setState(() {
        _scanned = false;
      });

      return true;
    } catch (e) {
      if (e.toString().contains("sufficient balance")) {
        AppLogger.instance.warn("No federation with sufficient balance");
        ToastService().show(
          message: "No federation with sufficient balance.",
          duration: const Duration(seconds: 5),
          onTap: () {},
          icon: Icon(Icons.error),
        );

        return true;
      }
    }

    return false;
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
      ToastService().show(
        message: "Clipboard is empty",
        duration: const Duration(seconds: 5),
        onTap: () {},
        icon: Icon(Icons.warning),
      );
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
