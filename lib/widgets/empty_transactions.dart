import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

class EmptyTransactionsState extends StatelessWidget {
  final PaymentType paymentType;
  final VoidCallback onReceivePressed;

  const EmptyTransactionsState({
    super.key,
    required this.paymentType,
    required this.onReceivePressed,
  });

  IconData _iconForType() {
    switch (paymentType) {
      case PaymentType.lightning:
        return Icons.flash_on;
      case PaymentType.onchain:
        return Icons.link;
      case PaymentType.ecash:
        return Icons.currency_bitcoin;
    }
  }

  String _messageForType(BuildContext context) {
    switch (paymentType) {
      case PaymentType.lightning:
        return context.l10n.noLightningTransactionsYet;
      case PaymentType.onchain:
        return context.l10n.noOnchainTransactionsYet;
      case PaymentType.ecash:
        return context.l10n.noEcashTransactionsYet;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Animate(
      effects: [FadeEffect(duration: 200.ms, curve: Curves.easeIn)],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_iconForType(), size: 48, color: Colors.grey[600]),
          const SizedBox(height: 16),
          Text(
            _messageForType(context),
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: Colors.grey),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
