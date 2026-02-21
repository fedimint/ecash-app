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
  _QrLoopSession? _currentSession;

  final List<_FountainFramePending> _pendingFountains = [];
  final Set<String> _exploredFountains = {};
  static const int FOUNTAIN_V1_CONST = 100;

  void _handleQrLoopChunk(String base64Str) async {
    if (_scanned) return;
    try {
      // If there is no current session, first try to just normally parse the text
      if (_currentSession == null) {
        setState(() {
          _scanned = true;
        });
        AppLogger.instance.info("Trying for first time to parse as non ecash");
        final parsed = await _handleText(base64Str);
        if (parsed) return;
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
        _exploredFountains.add(base64Str);

        final k = (bytes[1] << 8) | bytes[2];
        final indexes = <int>[];
        for (int j = 0; j < k; j++) {
          final idx = (bytes[3 + 2 * j] << 8) | bytes[4 + 2 * j];
          indexes.add(idx);
        }
        final data = bytes.sublist(3 + 2 * k);
        final fountainPending = _FountainFramePending(
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

        if (_currentSession == null || _currentSession!.nonce != nonce) {
          AppLogger.instance.info(
            "Starting new session! Nonce: $nonce TotalFrames: $totalFrames",
          );
          _currentSession = _QrLoopSession(
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
          _scanned = true;
          final merged = session.mergeChunks();
          _processMerged(merged);
        }
      }
    } catch (e) {
      AppLogger.instance.warn("Failed QR frame: $e");
      if (!_scanned) _onQRCodeScanned(base64Str);
    }
  }

  void _processMerged(Uint8List merged) async {
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
      AppLogger.instance.error("Payload: $payload");
      final actualPayload = utf8.decode(payload);
      AppLogger.instance.info("Decoded QR payload: $actualPayload");
      final parsed = await _handleText(actualPayload);
      if (!parsed) {
        ToastService().show(
          message: "Sorry! That cannot be parsed.",
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
              heightFactor: 0.33,
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
                    ecash: field1,
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
        case ParsedText_EcashNoFederation():
          ToastService().show(
            message:
                "Valid ecash detected, but we cannot determine the federation",
            duration: const Duration(seconds: 5),
            onTap: () {},
            icon: Icon(Icons.error),
          );
          break;
      }

      setState(() {
        _scanned = false;
        _currentSession = null;
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
    final parsed = await _handleText(code);
    if (!parsed) {
      AppLogger.instance.warn("$code cannot be parsed");
      ToastService().show(
        message: "Sorry! That cannot be parsed.",
        duration: const Duration(seconds: 5),
        onTap: () {},
        icon: Icon(Icons.error),
      );
    }
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

    final parsed = await _handleText(text);
    if (!parsed) {
      AppLogger.instance.warn("$text cannot be parsed");
      ToastService().show(
        message: "Sorry! That cannot be parsed.",
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

class _FountainFramePending {
  final String idBase64; // used for dedupe
  final int version;
  final List<int> indexes;
  final Uint8List data;

  _FountainFramePending(this.idBase64, this.version, this.indexes, this.data);

  _FountainFrame toFountainFrame() => _FountainFrame(version, indexes, data);
}

class _FountainFrame {
  final int version;
  final List<int> indexes;
  final Uint8List data;

  _FountainFrame(this.version, this.indexes, this.data);
}

class _QrLoopSession {
  final int nonce;
  final int totalFrames;
  final Map<int, Uint8List> chunks = {};
  final List<_FountainFrame> fountains = [];

  _QrLoopSession({required this.nonce, required this.totalFrames});

  bool get isComplete => chunks.length >= totalFrames;

  bool addDataFrame(int frameIndex, Uint8List data) {
    if (!chunks.containsKey(frameIndex)) {
      chunks[frameIndex] = data;
      _tryRecover();
      return true;
    }
    return false;
  }

  void addFountainFrame(_FountainFrame f) {
    fountains.add(f);
    _tryRecover();
  }

  void _tryRecover() {
    bool progress = true;
    while (progress) {
      progress = false;

      for (int i = 0; i < fountains.length;) {
        final f = fountains[i];

        // which indexes are missing
        final missing =
            f.indexes.where((idx) => !chunks.containsKey(idx)).toList();

        // collect known frames' data for the indexes present
        final existingFramesData = <Uint8List>[];
        for (final idx in f.indexes) {
          final known = chunks[idx];
          if (known != null) existingFramesData.add(known);
        }

        if (existingFramesData.isNotEmpty) {
          // compute min length among known frames
          final minKnownLen = existingFramesData
              .map((d) => d.length)
              .reduce((a, b) => a < b ? a : b);

          // If fountain length does not match min known length, drop the fountain (incompatible).
          if (f.data.length != minKnownLen) {
            AppLogger.instance.info(
              "Dropping fountain: incompatible length (f.len=${f.data.length} minKnownLen=$minKnownLen)",
            );
            fountains.removeAt(i);
            continue;
          }
        }

        if (missing.isEmpty) {
          // fountain is useless now, remove it
          fountains.removeAt(i);
          continue;
        } else if (missing.length == 1) {
          // we can recover that missing chunk
          final int missingIndex = missing.first;

          // start with fountain data as Uint8List; we will XOR known frames into it
          // produce result length = f.data.length (should equal min known length per above)
          Uint8List recovered = Uint8List.fromList(f.data);

          // XOR existing frames (only up to recovered.length, because we've validated lengths)
          for (final idx in f.indexes) {
            if (idx == missingIndex) continue;
            final known = chunks[idx]!;
            // XOR only up to recovered.length
            for (int j = 0; j < recovered.length; j++) {
              recovered[j] = recovered[j] ^ known[j];
            }
          }

          // store recovered chunk
          chunks[missingIndex] = recovered;
          AppLogger.instance.info(
            "Recovered missing chunk $missingIndex from fountain (now have ${chunks.length}/$totalFrames)",
          );

          // remove fountain and restart loop (some fountains may now be usable)
          fountains.removeAt(i);
          progress = true;
          // restart scanning fountains from beginning
          i = 0;
          continue;
        } else {
          // cannot do anything for this fountain yet
          i++;
        }
      } // end for fountains
    } // end while progress
  }

  Uint8List mergeChunks() {
    final List<int> fullData = [];
    for (int i = 0; i < totalFrames; i++) {
      final c = chunks[i];
      if (c == null) {
        throw Exception(
          "Missing chunk $i during merge (have ${chunks.keys.toList()})",
        );
      }
      fullData.addAll(c);
    }
    return Uint8List.fromList(fullData);
  }
}
