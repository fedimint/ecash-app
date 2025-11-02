import 'package:ecashapp/db.dart';
import 'package:ecashapp/detail_row.dart';
import 'constants/transaction_keys.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/providers/preferences_provider.dart';
import 'package:ecashapp/send.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class PaymentPreviewWidget extends StatelessWidget {
  final FederationSelector fed;
  final PaymentPreview paymentPreview;

  const PaymentPreviewWidget({
    super.key,
    required this.fed,
    required this.paymentPreview,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bitcoinDisplay = context.select<PreferencesProvider, BitcoinDisplay>((prefs) => prefs.bitcoinDisplay);
    final amount = paymentPreview.amountMsats;
    final amountWithFees = paymentPreview.amountWithFees;
    final fees = amountWithFees - amount;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Confirm Lightning Payment',
          style: theme.textTheme.headlineSmall?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 24),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainer,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: theme.colorScheme.primary.withOpacity(0.25),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CopyableDetailRow(
                label: "Payer Federation",
                value: fed.federationName,
              ),
              CopyableDetailRow(
                label: TransactionDetailKeys.amount,
                value: formatBalance(amount, true, bitcoinDisplay),
              ),
              CopyableDetailRow(
                label: TransactionDetailKeys.fees,
                value: formatBalance(fees, true, bitcoinDisplay),
              ),
              CopyableDetailRow(
                label: TransactionDetailKeys.total,
                value: formatBalance(amountWithFees, true, bitcoinDisplay),
              ),
              CopyableDetailRow(
                label: TransactionDetailKeys.gateway,
                value: paymentPreview.gateway,
              ),
              CopyableDetailRow(
                label: TransactionDetailKeys.paymentHash,
                value: paymentPreview.paymentHash,
              ),
            ],
          ),
        ),
        const SizedBox(height: 32),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            icon: const Icon(Icons.send, color: Colors.black),
            label: const Text('Send Payment'),
            style: ElevatedButton.styleFrom(
              backgroundColor: theme.colorScheme.primary,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder:
                      (context) => SendPayment(
                        fed: fed,
                        invoice: paymentPreview.invoice,
                        amountMsats: amount,
                        gateway: paymentPreview.gateway,
                        isLnv2: paymentPreview.isLnv2,
                        amountMsatsWithFees: paymentPreview.amountWithFees,
                      ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 24), // Padding to prevent tight bottom
      ],
    );
  }
}
