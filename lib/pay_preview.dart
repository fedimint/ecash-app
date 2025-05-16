import 'package:carbine/lib.dart';
import 'package:carbine/main.dart';
import 'package:carbine/send.dart';
import 'package:carbine/theme.dart';
import 'package:flutter/material.dart';

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
    final amount = paymentPreview.amountMsats;
    final feeFromPpm =
        (amount * paymentPreview.sendFeePpm) ~/ BigInt.from(1_000_000);
    final fedFee = paymentPreview.fedFee;
    final fees = paymentPreview.sendFeeBase + feeFromPpm + fedFee;
    final total = amount + fees;

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
              buildDetailRow(theme, "Payer Federation", fed.federationName),
              buildDetailRow(theme, 'Amount', formatBalance(amount, true)),
              buildDetailRow(theme, 'Fees', formatBalance(fees, true)),
              buildDetailRow(theme, 'Total', formatBalance(total, true)),
              buildDetailRow(theme, 'Gateway', paymentPreview.gateway),
              buildDetailRow(theme, 'Payment Hash', paymentPreview.paymentHash),
            ],
          ),
        ),
        const SizedBox(height: 32),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            icon: const Icon(Icons.send, color: Colors.white),
            label: const Text(
              'Send Payment',
              style: TextStyle(color: Colors.white),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: theme.colorScheme.primary,
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
