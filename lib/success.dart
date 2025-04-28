import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

class Success extends StatelessWidget {
  const Success({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Animate(
        effects: [
          ScaleEffect(
            duration: 600.ms,
            curve: Curves.easeOutBack,
          ),
          FadeEffect(
            duration: 600.ms,
            curve: Curves.easeIn,
          ),
        ],
        child: Column(
          mainAxisSize: MainAxisSize.min,
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

            // "Payment Received!" Text
            const Text(
              'Payment Received!',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),

            const SizedBox(height: 12),

            // Optional softer secondary text
            Text(
              'Thank you for your payment',
              style: TextStyle(
                fontSize: 18,
                color: Colors.black54,
              ),
            ),
          ],
        ),
      ),
    );
  }
}