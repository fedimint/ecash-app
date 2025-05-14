import 'package:carbine/lib.dart';
import 'package:carbine/success.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

class Request extends StatefulWidget {
  final String invoice;
  final OperationId operationId;
  final FederationSelector fed;
  final BigInt amountMsats;

  const Request({
    super.key,
    required this.invoice,
    required this.operationId,
    required this.fed,
    required this.amountMsats,
  });

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

  void _waitForPayment() async {
    await awaitReceive(
      federationId: widget.fed.federationId,
      operationId: widget.operationId,
    );
    setState(() {
      _received = true;
    });
    await Future.delayed(const Duration(seconds: 4));
    Navigator.of(context, rootNavigator: true).popUntil((route) => route.isFirst);
  }

  String _getAbbreviatedInvoice(String invoice) {
    if (invoice.length <= 14) return invoice;
    return '${invoice.substring(0, 7)}...${invoice.substring(invoice.length - 7)}';
  }

  @override
  Widget build(BuildContext context) {
    final abbreviatedInvoice = _getAbbreviatedInvoice(widget.invoice);
    final theme = Theme.of(context);
    final qrSize = MediaQuery.of(context).size.width * 0.8;

    if (_received) {
      return SafeArea(
        child: Scaffold(
          body: Success(
            lightning: true,
            received: true,
            amountMsats: widget.amountMsats,
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Lightning Request',
          style: theme.textTheme.titleLarge?.copyWith(fontSize: 22),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        Center(
          child: QrImageView(
            data: widget.invoice,
            version: QrVersions.auto,
            size: qrSize,
            backgroundColor: Colors.white,
          ),
        ),
        const SizedBox(height: 24),
        Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: theme.colorScheme.primary.withOpacity(0.5)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  abbreviatedInvoice,
                  style: theme.textTheme.bodyLarge,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.copy),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: widget.invoice));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Invoice copied to clipboard'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}
