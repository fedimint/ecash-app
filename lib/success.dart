import 'package:carbine/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:lottie/lottie.dart';

class Success extends StatelessWidget {
  final bool lightning;
  final bool received;
  final BigInt amountMsats;

  const Success({
    super.key,
    required this.lightning,
    required this.received,
    required this.amountMsats,
  });

  @override
  Widget build(BuildContext context) {
    final actionText = received ? 'received' : 'sent';
    final displayAmount = formatBalance(amountMsats, false);

    return Scaffold(
      body: Stack(
        alignment: Alignment.center,
        children: [
          // Lightning Animation (conditional)
          if (lightning)
            Positioned.fill(
              child: Lottie.asset(
                'assets/animations/lightning.json',
                fit: BoxFit.cover,
                repeat: true,
              ),
            ),

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
                  // Green Circle with Check Icon
                  Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.greenAccent.withOpacity(0.8),
                    ),
                    padding: const EdgeInsets.all(24),
                    child: const Icon(
                      Icons.check,
                      size: 64,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Success message
                  Text(
                    'You $actionText $displayAmount',
                    style: const TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
