import 'package:carbine/lib.dart';
import 'package:carbine/success.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

class Request extends StatefulWidget {
  final String invoice;
  final OperationId operationId;
  final FederationSelector fed;
  final BigInt amountSats;

  const Request({super.key, required this.invoice, required this.operationId, required this.fed, required this.amountSats});

  @override
  State<Request> createState() => _RequestState();
}

class _RequestState extends State<Request> {
  bool _received = false;

  @override
  void initState() {
    super.initState();
    _waitForPayment();
  }

  // TODO: This needs to be called in an background thread not tied to the widget
  // otherwise, set_operation_outcome will not be called and it wont show up in the transaction list
  // or we can drive these operations to completion on the rust side
  void _waitForPayment() async {
    await awaitReceive(federationId: widget.fed.federationId, operationId: widget.operationId);
    setState(() {
      _received = true;
    });
    await Future.delayed(Duration(seconds: 4));
    Navigator.of(context, rootNavigator: true).popUntil((route) => route.isFirst);
  }

  String _getAbbreviatedInvoice(String invoice) {
    if (invoice.length <= 14) {
      return invoice;
    }
    return '${invoice.substring(0, 7)}...${invoice.substring(invoice.length - 7)}';
  }

  @override
  Widget build(BuildContext context) {
    String abbreviatedInvoice = _getAbbreviatedInvoice(widget.invoice);

    if (_received) {
      return SafeArea(
        child: Scaffold(
          // TODO: This is a bit weird, for LNv2 we are showing the invoice amount, not the amount received
          // after fees
          body: Success(lightning: true, received: true, amount: widget.amountSats),
        )
      );
    }

    return SafeArea(
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Lightning Request', style: TextStyle(fontWeight: FontWeight.bold)),
          centerTitle: true,
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
        backgroundColor: Colors.white,
        body: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // QR Code
              Center(
                child: QrImageView(
                  data: widget.invoice,
                  version: QrVersions.auto,
                  size: 500.0,
                ),
              ),
              const SizedBox(height: 24),

              // "Lightning Invoice" label in bold
              const Text(
                'Lightning Invoice',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
              ),
              const SizedBox(height: 8),

              // Display abbreviated invoice in a copyable box
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey),
                ),
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        abbreviatedInvoice,
                        style: TextStyle(fontSize: 16, color: Colors.black87),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: widget.invoice));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Invoice copied to clipboard')),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}