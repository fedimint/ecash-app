import 'package:carbine/lib.dart';
import 'package:carbine/main.dart';
import 'package:carbine/success.dart';
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
              Navigator.push(context, MaterialPageRoute(builder: (context) => SendPayment(fed: fed, invoice: paymentPreview.invoice, amountMsats: amount)));
            },
          ),
        ),
        const SizedBox(height: 24), // Padding to prevent tight bottom
      ],
    );
  }
}

class SendPayment extends StatefulWidget {
  final FederationSelector fed;
  final String invoice;
  final BigInt amountMsats;

  const SendPayment({
    super.key,
    required this.fed,
    required this.invoice,
    required this.amountMsats,
  });

  @override
  State<SendPayment> createState() => _SendPaymentState();
}

class _SendPaymentState extends State<SendPayment> {
  bool _isSending = true;

  @override
  void initState() {
    super.initState();
    _payInvoice();
  }

  void _payInvoice() async {
    try {
      final operationId = await send(
        federationId: widget.fed.federationId,
        invoice: widget.invoice,
      );

      final finalState = await awaitSend(
        federationId: widget.fed.federationId,
        operationId: operationId,
      );

      debugPrint('FinalState: $finalState');

      if (!mounted) return;

      setState(() {
        _isSending = false;
      });

      // Navigate to Success screen
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => Success(
            lightning: true,
            received: false,
            amountMsats: widget.amountMsats,
          ),
        ),
      );

      await Future.delayed(const Duration(seconds: 4));

      if (mounted) {
        Navigator.of(context, rootNavigator: true).popUntil((route) => route.isFirst);
      }
    } catch (e) {
      debugPrint('Error while sending payment: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to send payment')),
      );
      Navigator.of(context).pop(); // Close modal on failure
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 500),
        child: _isSending
            ? Column(
                key: const ValueKey('sending'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 24),
                  CircularProgressIndicator(
                    valueColor: AlwaysStoppedAnimation(theme.colorScheme.primary),
                    strokeWidth: 3,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Sending Payment',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ],
              )
            : const SizedBox.shrink(), // Replaced by Success screen
      ),
    );
  }
}