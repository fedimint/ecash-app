import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

class EmptyTransactionsState extends StatelessWidget {
  final PaymentType paymentType;
  final VoidCallback onReceivePressed;
  final VoidCallback onActionPressed;

  const EmptyTransactionsState({
    super.key,
    required this.paymentType,
    required this.onReceivePressed,
    required this.onActionPressed,
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

  IconData _actionIconForType() {
    switch (paymentType) {
      case PaymentType.lightning:
        return Icons.device_hub;
      case PaymentType.onchain:
        return Icons.account_balance_wallet;
      case PaymentType.ecash:
        return Icons.receipt_long;
    }
  }

  String _actionLabelForType(BuildContext context) {
    switch (paymentType) {
      case PaymentType.lightning:
        return context.l10n.viewGateways;
      case PaymentType.onchain:
        return context.l10n.viewAddresses;
      case PaymentType.ecash:
        return context.l10n.viewNotes;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Animate(
      effects: [
        ScaleEffect(duration: 200.ms, curve: Curves.easeOutBack),
        FadeEffect(duration: 200.ms, curve: Curves.easeIn),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_iconForType(), size: 48, color: Colors.grey[600]),
          const SizedBox(height: 16),
          Text(
            _messageForType(context),
            style: theme.textTheme.bodyMedium?.copyWith(color: Colors.grey),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FilledButton.icon(
                icon: const Icon(Icons.download),
                label: Text(context.l10n.receive),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(0, 48),
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                ),
                onPressed: onReceivePressed,
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                icon: Icon(_actionIconForType()),
                label: Text(_actionLabelForType(context)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: theme.colorScheme.primary,
                  side: BorderSide(
                    color: theme.colorScheme.primary.withOpacity(0.5),
                  ),
                  minimumSize: const Size(0, 48),
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                ),
                onPressed: onActionPressed,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
