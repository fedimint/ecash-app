import 'package:carbine/lib.dart';
import 'package:carbine/main.dart';
import 'package:carbine/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
    final feeFromPpm = (amount * paymentPreview.sendFeePpm) ~/ BigInt.from(1_000_000);
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
            border: Border.all(color: theme.colorScheme.primary.withOpacity(0.25)),
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
              print("PayInvoice pressed");
            },
          ),
        ),
        const SizedBox(height: 24), // Padding to prevent tight bottom
      ],
    );
  }
}


/*
class _PaymentPreviewState extends State<PaymentPreviewWidget> {

  void _payInvoice() async {
    setState(() {
      state = PaymentState.Paying;
    });

    final operationId = await send(federationId: widget.fed.federationId, invoice: widget.paymentPreview.invoice);
    final finalState = await awaitSend(federationId: widget.fed.federationId, operationId: operationId);
    print('FinalState: $finalState');

    setState(() {
      state = PaymentState.Success;
    });
    Navigator.push(context, MaterialPageRoute(builder: (context) => Success(
      lightning: true,
      received: false,
      amountMsats: widget.paymentPreview.amountMsats,
    )));
    await Future.delayed(Duration(seconds: 4));
    Navigator.of(context, rootNavigator: true).popUntil((route) => route.isFirst);
  }
}
*/