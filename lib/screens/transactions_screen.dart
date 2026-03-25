import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/models.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/widgets/transactions_list.dart';
import 'package:flutter/material.dart';

class TransactionsScreen extends StatelessWidget {
  final FederationSelector fed;
  final PaymentType paymentType;
  final VoidCallback onClaimed;
  final VoidCallback? onWithdrawCompleted;

  const TransactionsScreen({
    super.key,
    required this.fed,
    required this.paymentType,
    required this.onClaimed,
    this.onWithdrawCompleted,
  });

  String _title(BuildContext context) {
    switch (paymentType) {
      case PaymentType.lightning:
        return context.l10n.lightning;
      case PaymentType.onchain:
        return context.l10n.onchain;
      case PaymentType.ecash:
        return context.l10n.ecash;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_title(context))),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: TransactionsList(
            fed: fed,
            selectedPaymentType: paymentType,
            recovering: false,
            onClaimed: onClaimed,
            onWithdrawCompleted: onWithdrawCompleted,
          ),
        ),
      ),
    );
  }
}
