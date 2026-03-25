import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/models.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/widgets/payment_type_sheet.dart';
import 'package:ecashapp/widgets/transactions_list.dart';
import 'package:flutter/material.dart';

class TransactionsScreen extends StatelessWidget {
  final FederationSelector fed;
  final PaymentType paymentType;
  final VoidCallback onClaimed;
  final VoidCallback? onWithdrawCompleted;
  final VoidCallback? onAddressesUpdated;

  const TransactionsScreen({
    super.key,
    required this.fed,
    required this.paymentType,
    required this.onClaimed,
    this.onWithdrawCompleted,
    this.onAddressesUpdated,
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

  void _onActionPressed(BuildContext context) {
    showPaymentTypeSheet(
      context: context,
      paymentType: paymentType,
      fed: fed,
      onAddressesUpdated: onAddressesUpdated,
    );
  }

  IconData _actionIcon() {
    switch (paymentType) {
      case PaymentType.lightning:
        return Icons.device_hub;
      case PaymentType.onchain:
        return Icons.account_balance_wallet;
      case PaymentType.ecash:
        return Icons.receipt_long;
    }
  }

  String _actionTooltip(BuildContext context) {
    switch (paymentType) {
      case PaymentType.lightning:
        return context.l10n.gateways;
      case PaymentType.onchain:
        return context.l10n.addresses;
      case PaymentType.ecash:
        return context.l10n.notes;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_title(context)),
        actions: [
          IconButton(
            icon: Icon(_actionIcon()),
            tooltip: _actionTooltip(context),
            onPressed: () => _onActionPressed(context),
          ),
        ],
      ),
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
