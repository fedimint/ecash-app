import 'package:carbine/lib.dart';
import 'package:carbine/success.dart';
import 'package:flutter/material.dart';

class PaymentPreviewWidget extends StatefulWidget {
  final FederationSelector fed;
  final PaymentPreview paymentPreview;

  const PaymentPreviewWidget({
    super.key,
    required this.fed,
    required this.paymentPreview,
  });

  @override
  State<PaymentPreviewWidget> createState() => _PaymentPreviewState();
}

enum PaymentState {
  Preview,
  Paying,
  Success,
}

class _PaymentPreviewState extends State<PaymentPreviewWidget> {
  PaymentState state = PaymentState.Preview;

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
    await Future.delayed(Duration(seconds: 4));
    Navigator.of(context, rootNavigator: true).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    if (state == PaymentState.Success) {
      return SafeArea(
        child: Scaffold(
          body: Success(lightning: true, received: false, amountMsats: widget.paymentPreview.amount),
        ),
      );
    }

    if (state == PaymentState.Paying) {
      return SafeArea(
        child: Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 24),
                Text(
                  'Sending Payment...',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 5,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: Colors.grey[400],
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              'Confirm Payment',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
          ),
          const SizedBox(height: 24),
          Center(
            child: Text(
              '${widget.paymentPreview.amount} msats',
              style: Theme.of(context).textTheme.displaySmall?.copyWith(
                    color: Colors.green[700],
                    fontWeight: FontWeight.bold,
                  ),
            ),
          ),
          const SizedBox(height: 24),
          Card(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            elevation: 4,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Federation:',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 4),
                  Text(widget.fed.federationName),
                  const SizedBox(height: 16),
                  Text(
                    'Payment Hash:',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 4),
                  SelectableText(
                    widget.paymentPreview.paymentHash,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Invoice:',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 4),
                  SelectableText(
                    widget.paymentPreview.invoice,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              icon: const Icon(Icons.send, color: Colors.white),
              label: const Text(
                'Send Payment',
                style: TextStyle(color: Colors.white),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green[700],
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              onPressed: _payInvoice,
            ),
          ),
        ],
      ),
    );
  }
}