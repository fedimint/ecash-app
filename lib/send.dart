import 'package:ecashapp/failure.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/success.dart';
import 'package:ecashapp/toast.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';

class SendPayment extends StatefulWidget {
  final FederationSelector fed;
  final String? invoice;
  final String? lnAddress;
  final BigInt amountMsats;
  final String? gateway;
  final bool? isLnv2;
  final BigInt? amountMsatsWithFees;

  const SendPayment({
    super.key,
    required this.fed,
    required this.amountMsats,
    this.gateway,
    this.isLnv2,
    this.invoice,
    this.lnAddress,
    this.amountMsatsWithFees,
  });

  @override
  State<SendPayment> createState() => _SendPaymentState();
}

class _SendPaymentState extends State<SendPayment> {
  bool _isSending = true;

  String _mapSendErrorToMessage(Object error) {
    final raw = error.toString();
    final lower = raw.toLowerCase();

    if (lower.contains('insufficient') ||
        lower.contains('not enough funds') ||
        lower.contains('insufficient funds') ||
        lower.contains('insufficient balance')) {
      return 'Insufficient balance to pay this invoice (including fees).';
    }

    if (lower.contains('expired') ||
        lower.contains('invoice has expired') ||
        lower.contains('invoice expired')) {
      return 'This invoice has expired and can no longer be paid.';
    }

    if (lower.contains('route') ||
        lower.contains('routing') ||
        lower.contains('no route') ||
        lower.contains('could not find a route')) {
      return 'Could not route your payment. Try a smaller amount or try again later.';
    }

    // Fallback: include a short version of the backend message if present
    const maxLength = 120;
    final trimmed =
        raw.length <= maxLength ? raw : '${raw.substring(0, maxLength)}…';
    return trimmed.isEmpty ? 'Failed to send payment.' : trimmed;
  }

  @override
  void initState() {
    super.initState();
    _payInvoice();
  }

  Future<OperationId> _sendPayment() async {
    if (widget.invoice != null) {
      final operationId = await send(
        federationId: widget.fed.federationId,
        invoice: widget.invoice!,
        gateway: widget.gateway!,
        isLnv2: widget.isLnv2!,
        amountWithFees: widget.amountMsatsWithFees!,
      );
      return operationId;
    } else {
      // When sending via LN address, gateway is selected internally
      final operationId = await sendLnaddress(
        federationId: widget.fed.federationId,
        amountMsats: widget.amountMsats,
        address: widget.lnAddress!,
      );
      return operationId;
    }
  }

  void _payInvoice() async {
    try {
      final operationId = await _sendPayment();
      final finalState = await awaitSend(
        federationId: widget.fed.federationId,
        operationId: operationId,
      );

      if (!mounted) return;

      if (finalState is LightningSendOutcome_Success) {
        // Navigate to Success screen
        Navigator.push(
          context,
          MaterialPageRoute(
            builder:
                (context) => Success(
                  lightning: true,
                  received: false,
                  amountMsats: widget.amountMsats,
                ),
          ),
        );

        await Future.delayed(const Duration(seconds: 4));

        if (mounted) {
          Navigator.of(context).popUntil((route) => route.isFirst);
        }
      } else {
        AppLogger.instance.error('Payment was unsuccessful');

        // Navigate to Failure screen
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => Failure(amountMsats: widget.amountMsats),
          ),
        );

        await Future.delayed(const Duration(seconds: 4));

        if (mounted) {
          Navigator.of(context).popUntil((route) => route.isFirst);
        }
      }
    } catch (e, stackTrace) {
      AppLogger.instance.error('Error while sending payment: $e');
      AppLogger.instance.error('Stack trace while sending payment: $stackTrace');
      if (!mounted) return;
      ToastService().show(
        message: _mapSendErrorToMessage(e),
        duration: const Duration(seconds: 5),
        onTap: () {},
        icon: Icon(Icons.error),
      );
      Navigator.of(context).pop(); // Close modal on failure
    }

    setState(() {
      _isSending = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 500),
        child:
            _isSending
                ? Column(
                  key: const ValueKey('sending'),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 24),
                    CircularProgressIndicator(
                      valueColor: AlwaysStoppedAnimation(
                        theme.colorScheme.primary,
                      ),
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
