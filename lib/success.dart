import 'dart:async';
import 'package:ecashapp/generated/db.dart';
import 'package:ecashapp/providers/preferences_provider.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:lottie/lottie.dart';
import 'package:provider/provider.dart';

class Success extends StatefulWidget {
  final bool lightning;
  final bool received;
  final BigInt amountMsats;
  final String? txid;
  final VoidCallback? onCompleted;

  const Success({
    super.key,
    required this.lightning,
    required this.received,
    required this.amountMsats,
    this.txid,
    this.onCompleted,
  });

  @override
  State<Success> createState() => _SuccessState();
}

class _SuccessState extends State<Success> {
  Timer? _autoDismissTimer;

  @override
  void initState() {
    super.initState();
    _startAutoDismissTimer();
  }

  @override
  void dispose() {
    _autoDismissTimer?.cancel();
    super.dispose();
  }

  void _startAutoDismissTimer() {
    _autoDismissTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) {
        widget.onCompleted?.call();
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    });
  }

  void _dismissNow() {
    _autoDismissTimer?.cancel();
    widget.onCompleted?.call();
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final bitcoinDisplay = context.select<PreferencesProvider, BitcoinDisplay>((prefs) => prefs.bitcoinDisplay);
    final actionText = widget.received ? 'received' : 'sent';
    final displayAmount = formatBalance(widget.amountMsats, false, bitcoinDisplay);

    return Scaffold(
      body: GestureDetector(
        onTap: _dismissNow,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Lightning Animation (conditional)
            if (widget.lightning)
              Positioned.fill(child: Lottie.asset('assets/animations/lightning.json', fit: BoxFit.cover, repeat: true)),

            // Main Animated Success Content (centered)
            Center(
              child: Animate(
                effects: [
                  ScaleEffect(duration: 600.ms, curve: Curves.easeOutBack),
                  FadeEffect(duration: 600.ms, curve: Curves.easeIn),
                ],
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Blue Circle with Check Icon
                    Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Theme.of(context).colorScheme.primary.withOpacity(0.8),
                      ),
                      padding: const EdgeInsets.all(24),
                      child: const Icon(Icons.check, size: 64, color: Colors.white),
                    ),
                    const SizedBox(height: 24),

                    // Success message
                    Text(
                      'You $actionText $displayAmount',
                      style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    if (widget.txid != null) ...[
                      Text(
                        'Transaction ID:',
                        style: TextStyle(fontSize: 14, color: Colors.grey[600], fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(height: 4),
                      SelectableText(
                        widget.txid!,
                        style: TextStyle(fontSize: 12, color: Colors.grey[400], fontFamily: 'monospace'),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
