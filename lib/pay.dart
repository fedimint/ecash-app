import 'package:carbine/lib.dart';
import 'package:flutter/material.dart';

class Pay extends StatefulWidget {
  final FederationSelector fed;
  final PaymentPreview paymentPreview;

  const Pay({super.key, required this.fed, required this.paymentPreview});

  @override
  State<Pay> createState() => _PayState();
}

class _PayState extends State<Pay> {
  bool _isPaying = false;

  Future<void> _makePayment() async {
    setState(() {
      _isPaying = true;
    });

    try {
      final operationId = await send(federationId: widget.fed.federationId, invoice: widget.paymentPreview.invoice);
      await awaitSend(federationId: widget.fed.federationId, operationId: operationId);

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Payment Success")),
        );

        Navigator.pop(context);
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Failed to make payment")),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isPaying = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Pay Invoice")),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("Would you like to pay this invoice?", style: TextStyle(fontSize: 18)),
            const SizedBox(height: 16),
            Text("Federation: ${widget.fed.federationName}"),
            Text("Amount: ${widget.paymentPreview.amount} msat"),
            Text("Payment Hash: ${widget.paymentPreview.paymentHash}"),
            const Spacer(),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isPaying ? null : _makePayment,
                child: _isPaying
                    ? const CircularProgressIndicator(color: Colors.white)
                    : const Text("Pay"),
              ),
            ),
          ],
        ),
      ),
    );
  }
}