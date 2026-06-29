import 'package:ecashapp/error_helper.dart';
import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/failure.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/success.dart';
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
  final BigInt? federationFeeMsats;
  final BigInt? gatewayFeeMsats;

  const SendPayment({
    super.key,
    required this.fed,
    required this.amountMsats,
    this.gateway,
    this.isLnv2,
    this.invoice,
    this.lnAddress,
    this.amountMsatsWithFees,
    this.federationFeeMsats,
    this.gatewayFeeMsats,
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

  Future<OperationId> _sendPayment() async {
    if (widget.invoice != null) {
      final operationId = await send(
        federationId: widget.fed.federationId,
        invoice: widget.invoice!,
        gateway: widget.gateway!,
        isLnv2: widget.isLnv2!,
        amountWithFees: widget.amountMsatsWithFees!,
        federationFeeMsats: widget.federationFeeMsats ?? BigInt.zero,
        gatewayFeeMsats: widget.gatewayFeeMsats ?? BigInt.zero,
        // When the invoice was resolved from a Lightning Address, thread it
        // through so it's recorded and shown in the transaction details.
        lnAddress: widget.lnAddress,
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
      } else if (finalState is LightningSendOutcome_Failure) {
        AppLogger.instance.error(
          'Payment was unsuccessful: ${finalState.field0}',
        );

        // Navigate to Failure screen with the typed error so the screen can
        // render a specific reason.
        Navigator.push(
          context,
          MaterialPageRoute(
            builder:
                (context) => Failure(
                  amountMsats: widget.amountMsats,
                  error: finalState.field0,
                ),
          ),
        );

        await Future.delayed(const Duration(seconds: 4));

        if (mounted) {
          Navigator.of(context).popUntil((route) => route.isFirst);
        }
      }
    } catch (e) {
      AppLogger.instance.error('Error while sending payment: $e');
      if (!mounted) return;
      showErrorToast(context, e);
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
                      context.l10n.sendingPayment,
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
