import 'dart:async';

import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/success.dart';
import 'package:ecashapp/toast.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

enum _WithdrawState { executing, waitingForPayment }

/// Generates a Lightning invoice for the chosen amount, posts it to the LNURLw
/// callback, and waits for the external service (e.g. a Boltcard terminal) to
/// pay it. The federation, gateway and amount are all selected on the number
/// pad before this screen is pushed.
class LnurlWithdrawWaiting extends StatefulWidget {
  final FederationSelector fed;
  final FedimintGateway gateway;
  final LnurlWithdrawParams params;
  final BigInt requestedMsats;

  const LnurlWithdrawWaiting({
    super.key,
    required this.fed,
    required this.gateway,
    required this.params,
    required this.requestedMsats,
  });

  @override
  State<LnurlWithdrawWaiting> createState() => _LnurlWithdrawWaitingState();
}

class _LnurlWithdrawWaitingState extends State<LnurlWithdrawWaiting> {
  _WithdrawState _state = _WithdrawState.executing;

  @override
  void initState() {
    super.initState();
    _execute();
  }

  Future<void> _execute() async {
    final params = widget.params;
    final gateway = widget.gateway;
    final requestedMsats = widget.requestedMsats;

    OperationId opId;
    try {
      final receiveAmount = await computeReceiveAmountWithFees(
        federationId: widget.fed.federationId,
        gatewayUrl: gateway.endpoint,
        isLnv2: gateway.isLnv2,
        amountMsats: requestedMsats,
        includeFees: false,
      );

      opId = await executeLnurlWithdraw(
        federationId: widget.fed.federationId,
        callback: params.callback,
        k1: params.k1,
        amountMsatsWithoutFees: requestedMsats,
        amountMsatsWithFees: receiveAmount.invoiceMsats,
        federationFeeMsats: receiveAmount.federationFeeMsats,
        gatewayFeeMsats: receiveAmount.gatewayFeeMsats,
        gatewayUrl: gateway.endpoint,
        isLnv2: gateway.isLnv2,
      );
    } catch (e) {
      AppLogger.instance.error('LNURLw execute failed: $e');
      if (!mounted) return;
      _showError();
      Navigator.of(context).pop();
      return;
    }

    if (!mounted) return;
    setState(() => _state = _WithdrawState.waitingForPayment);

    try {
      await awaitReceive(
        federationId: widget.fed.federationId,
        operationId: opId,
      ).timeout(const Duration(minutes: 5));
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder:
              (_) => Success(
                lightning: true,
                received: true,
                amountMsats: requestedMsats,
              ),
        ),
      );
      await Future.delayed(const Duration(seconds: 4));
    } on TimeoutException {
      AppLogger.instance.error(
        'LNURLw await_receive timed out after 5 minutes',
      );
      if (!mounted) return;
      _showError();
    } catch (e) {
      AppLogger.instance.error('LNURLw await_receive failed: $e');
      if (!mounted) return;
      _showError();
    } finally {
      if (mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    }
  }

  void _showError() {
    ToastService().show(
      message: context.l10n.lnurlWithdrawFailed,
      duration: const Duration(seconds: 5),
      onTap: () {},
      icon: const Icon(Icons.error),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.lnurlWithdrawTitle)),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: switch (_state) {
            _WithdrawState.executing => _StatusView(
              message: context.l10n.lnurlWithdrawRequesting,
            ),
            _WithdrawState.waitingForPayment => _StatusView(
              message: context.l10n.lnurlWithdrawWaiting,
              onCancel: () => Navigator.of(context).popUntil((r) => r.isFirst),
            ),
          },
        ),
      ),
    );
  }
}

class _StatusView extends StatelessWidget {
  final String message;
  final VoidCallback? onCancel;

  const _StatusView({required this.message, this.onCancel});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Animate(
        effects: [FadeEffect(duration: 300.ms)],
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: theme.colorScheme.primary),
            const SizedBox(height: 24),
            Text(
              message,
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            if (onCancel != null) ...[
              const SizedBox(height: 32),
              TextButton(
                onPressed: onCancel,
                child: Text(
                  MaterialLocalizations.of(context).cancelButtonLabel,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
