import 'dart:async';

import 'package:carbine/lib.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

class EcashSend extends StatefulWidget {
  final FederationSelector fed;
  final BigInt amountSats;

  const EcashSend({super.key, required this.fed, required this.amountSats});

  @override
  State<EcashSend> createState() => _EcashSendState();
}

class _EcashSendState extends State<EcashSend> with SingleTickerProviderStateMixin {
  String? _ecash;
  bool _loading = true;
  BigInt _ecashAmountMsats = BigInt.zero;
  bool _reclaiming = false;

  double _progress = 0.0;
  Timer? _holdTimer;

  static const Duration _holdDuration = Duration(seconds: 1);

  @override
  void initState() {
    super.initState();
    _loadEcash();
  }

  Future<void> _reclaimEcash() async {
    setState(() {
      _reclaiming = true;
    });
    if (_ecash != null) {
        final operationId = await reissueEcash(federationId: widget.fed.federationId, ecash: _ecash!);
        // TODO: Check outcome
        await awaitEcashReissue(federationId: widget.fed.federationId, operationId: operationId);
        Navigator.of(context, rootNavigator: true).popUntil((route) => route.isFirst);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('✅ Ecash reclaimed')),
      );
    }
    setState(() {
      _reclaiming = false;
    });
  }

  Future<void> _loadEcash() async {
    try {
      final ecash = await sendEcash(
        federationId: widget.fed.federationId,
        amountMsats: widget.amountSats * BigInt.from(1000),
      );
      setState(() {
        _ecash = ecash.$2;
        _loading = false;
        _ecashAmountMsats = ecash.$3 ~/ BigInt.from(1000);
      });
    } catch (e) {
      print('Error spending ecash: $e');
      setState(() {
        _ecash = null;
        _loading = false;
      });
    }
  }

  void _startHold() {
    setState(() {
      _progress = 0.0;
    });

    const tick = Duration(milliseconds: 20);
    int elapsed = 0;
    _holdTimer = Timer.periodic(tick, (timer) {
      elapsed += tick.inMilliseconds;
      final progress = elapsed / _holdDuration.inMilliseconds;
      if (progress >= 1.0) {
        print('Hold finished!');
        timer.cancel();
        _copyEcash();
        setState(() {
          _progress = 1.0;
        });
      } else {
        setState(() {
          _progress = progress;
        });
      }
    });
  }

  void _cancelHold() {
    _holdTimer?.cancel();
    setState(() {
      _progress = 0.0;
    });
  }

  void _copyEcash() {
    Navigator.of(context, rootNavigator: true).popUntil((route) => route.isFirst);
    Clipboard.setData(ClipboardData(text: _ecash!));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('✅ Ecash copied to clipboard')),
    );
  }

  String _abbreviate(String full, [int maxLen = 30]) {
    if (full.length <= maxLen) return full;
    return '${full.substring(0, 10)}...${full.substring(full.length - 10)}';
  }

  void _showToast(BuildContext context, String message) {
    final overlay = Overlay.of(context);
    final overlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        bottom: 100,
        left: 20,
        right: 20,
        child: Material(
          color: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.85),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              message,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );

    overlay.insert(overlayEntry);
    Future.delayed(const Duration(seconds: 2)).then((_) => overlayEntry.remove());
  }


  @override
  Widget build(BuildContext context) {
    final amount = _ecashAmountMsats.toString();
    return _loading
        ? const Center(child: CircularProgressIndicator())
        : _ecash == null
            ? const Center(child: Text("⚠️ Failed to load ecash"))
            : Padding(
                padding: const EdgeInsets.all(20),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.lock_outline, size: 48, color: Colors.green),
                      const SizedBox(height: 12),
                      Text(
                        "Ecash Withdrawn",
                        style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                              color: Colors.green[700],
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        "You have successfully removed $amount sats from your wallet.\n"
                        "You must now copy and send this ecash string to the recipient.",
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 24),

                      // QR code
                      Card(
                        elevation: 4,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: QrImageView(
                            data: _ecash!,
                            version: QrVersions.auto,
                            size: 300.0,
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),

                      // Abbreviated ecash
                      TextField(
                        readOnly: true,
                        controller: TextEditingController(
                          text: _abbreviate(_ecash!),
                        ),
                        decoration: InputDecoration(
                          prefixIcon: const Icon(Icons.key),
                          labelText: 'Ecash (abbreviated)',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),

                      // Hold to copy button with radial fill
                      GestureDetector(
                        onTapDown: (_) => _startHold(),
                        onTapUp: (_) => _cancelHold(),
                        onTapCancel: () => _cancelHold(),
                        onTap: () {
                          _showToast(context, "Hold to copy. This confirms that you’ve removed the ecash from your wallet.");
                        },
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            SizedBox(
                              width: 80,
                              height: 80,
                              child: CircularProgressIndicator(
                                value: _progress,
                                strokeWidth: 6,
                                backgroundColor: Colors.grey[300],
                                valueColor: AlwaysStoppedAnimation<Color>(Colors.green),
                              ),
                            ),
                            Container(
                              width: 60,
                              height: 60,
                              decoration: BoxDecoration(
                                color: Colors.green[700],
                                shape: BoxShape.circle,
                              ),
                              alignment: Alignment.center,
                              child: const Icon(Icons.copy, color: Colors.white),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 24),

                      // Reclaim button
                      _reclaiming
                          ? const CircularProgressIndicator()
                          : SizedBox(
                              width: double.infinity,
                              child: ElevatedButton.icon(
                                onPressed: _reclaimEcash,
                                icon: const Icon(Icons.undo),
                                label: const Text("Reclaim"),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.red[600],
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(vertical: 16),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                              ),
                            ),
                    ],
                  ),
                ),
              );
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    super.dispose();
  }
}

