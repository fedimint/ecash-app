import 'package:carbine/lib.dart';
import 'package:carbine/success.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

class Request extends StatefulWidget {
  final String invoice;
  final OperationId operationId;
  final FederationSelector fed;
  final BigInt requestedAmountMsats;
  final BigInt totalMsats;
  final String gateway;
  final String pubkey;
  final String paymentHash;
  final BigInt expiry;

  const Request({
    super.key,
    required this.invoice,
    required this.operationId,
    required this.fed,
    required this.requestedAmountMsats,
    required this.totalMsats,
    required this.gateway,
    required this.pubkey,
    required this.paymentHash,
    required this.expiry,
  });

  @override
  State<Request> createState() => _RequestState();
}

class _RequestState extends State<Request> with SingleTickerProviderStateMixin {
  bool _received = false;
  bool _copied = false;

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
    setState(() => _received = true);
    await Future.delayed(const Duration(seconds: 4));
    if (mounted) {
      Navigator.of(context, rootNavigator: true).popUntil((route) => route.isFirst);
    }
  }

  String _getAbbreviatedInvoice(String invoice) {
    if (invoice.length <= 14) return invoice;
    return '${invoice.substring(0, 7)}...${invoice.substring(invoice.length - 7)}';
  }

  void _copyInvoice() {
    Clipboard.setData(ClipboardData(text: widget.invoice));
    setState(() => _copied = true);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Invoice copied to clipboard'),
        duration: Duration(seconds: 2),
      ),
    );
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final abbreviatedInvoice = _getAbbreviatedInvoice(widget.invoice);

    if (_received) {
      return SafeArea(
        child: Scaffold(
          body: Success(
            lightning: true,
            received: true,
            amountMsats: widget.requestedAmountMsats,
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Lightning Request',
            style: theme.textTheme.headlineSmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: theme.colorScheme.primary.withOpacity(0.3),
                  blurRadius: 12,
                  spreadRadius: 1,
                ),
              ],
              border: Border.all(
                color: theme.colorScheme.primary.withOpacity(0.7),
                width: 1.5,
              ),
            ),
            child: AspectRatio(
              aspectRatio: 1, // Ensure square shape
              child: QrImageView(
                data: widget.invoice,
                version: QrVersions.auto,
                backgroundColor: Colors.white,
                padding: EdgeInsets.zero, // Remove internal padding
              ),
            ),
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: theme.colorScheme.primary.withOpacity(0.4)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    abbreviatedInvoice,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onSurface,
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  icon: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    transitionBuilder: (child, anim) =>
                        ScaleTransition(scale: anim, child: child),
                    child: _copied
                        ? Icon(Icons.check, key: const ValueKey('copied'), color: theme.colorScheme.primary)
                        : Icon(Icons.copy, key: const ValueKey('copy'), color: theme.colorScheme.primary),
                  ),
                  onPressed: _copyInvoice,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

