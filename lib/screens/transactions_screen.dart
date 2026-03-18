import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/models.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/widgets/addresses.dart';
import 'package:ecashapp/widgets/gateways.dart';
import 'package:ecashapp/widgets/note_summary.dart';
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
    Widget content;
    switch (paymentType) {
      case PaymentType.lightning:
        content = GatewaysList(fed: fed);
        break;
      case PaymentType.onchain:
        content = OnchainAddressesList(
          fed: fed,
          updateAddresses: () {
            onAddressesUpdated?.call();
          },
        );
        break;
      case PaymentType.ecash:
        content = NoteSummary(fed: fed);
        break;
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).bottomSheetTheme.backgroundColor,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return SafeArea(
          child: FractionallySizedBox(
            heightFactor: 0.8,
            child: Column(
              children: [
                Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.grey[700],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: content,
                  ),
                ),
              ],
            ),
          ),
        );
      },
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
