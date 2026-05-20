import 'dart:async';

import 'package:ecashapp/db.dart';
import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/providers/preferences_provider.dart';
import 'package:ecashapp/success.dart';
import 'package:ecashapp/toast.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:provider/provider.dart';

enum _WithdrawState { loading, showingDetails, executing, waitingForPayment }

class LnurlWithdrawScreen extends StatefulWidget {
  final String url;
  final FederationSelector fed;

  const LnurlWithdrawScreen({super.key, required this.url, required this.fed});

  @override
  State<LnurlWithdrawScreen> createState() => _LnurlWithdrawScreenState();
}

class _LnurlWithdrawScreenState extends State<LnurlWithdrawScreen> {
  _WithdrawState _state = _WithdrawState.loading;
  LnurlWithdrawParams? _params;

  @override
  void initState() {
    super.initState();
    _fetchParams();
  }

  Future<void> _fetchParams() async {
    try {
      final params = await fetchLnurlWithdraw(url: widget.url);
      if (!mounted) return;
      setState(() {
        _params = params;
        _state = _WithdrawState.showingDetails;
      });
    } catch (e) {
      AppLogger.instance.error('Failed to fetch LNURLw params: $e');
      if (!mounted) return;
      _showErrorAndPop(e.toString());
    }
  }

  Future<void> _onConfirm() async {
    final params = _params!;
    setState(() => _state = _WithdrawState.executing);

    OperationId opId;
    try {
      opId = await executeLnurlWithdraw(
        federationId: widget.fed.federationId,
        callback: params.callback,
        k1: params.k1,
        // Default to maxWithdrawable; a full amount picker is a follow-up.
        amountMsats: params.maxWithdrawableMsats,
      );
    } catch (e) {
      AppLogger.instance.error('LNURLw execute failed: $e');
      if (!mounted) return;
      _showErrorAndPop(e.toString());
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
                amountMsats: params.maxWithdrawableMsats,
              ),
        ),
      );
      await Future.delayed(const Duration(seconds: 4));
    } on TimeoutException {
      AppLogger.instance.error(
        'LNURLw await_receive timed out after 5 minutes',
      );
      if (!mounted) return;
      ToastService().show(
        message: context.l10n.lnurlWithdrawFailed,
        duration: const Duration(seconds: 5),
        onTap: () {},
        icon: const Icon(Icons.error),
      );
    } catch (e) {
      AppLogger.instance.error('LNURLw await_receive failed: $e');
      if (!mounted) return;
      ToastService().show(
        message: context.l10n.lnurlWithdrawFailed,
        duration: const Duration(seconds: 5),
        onTap: () {},
        icon: const Icon(Icons.error),
      );
    } finally {
      if (mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    }
  }

  void _showErrorAndPop(String error) {
    ToastService().show(
      message: context.l10n.lnurlWithdrawFailed,
      duration: const Duration(seconds: 5),
      onTap: () {},
      icon: const Icon(Icons.error),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.lnurlWithdrawTitle)),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: switch (_state) {
            _WithdrawState.loading => const Center(
              child: CircularProgressIndicator(),
            ),
            _WithdrawState.showingDetails => _DetailsView(
              params: _params!,
              fed: widget.fed,
              onConfirm: _onConfirm,
            ),
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

class _DetailsView extends StatelessWidget {
  final LnurlWithdrawParams params;
  final FederationSelector fed;
  final VoidCallback onConfirm;

  const _DetailsView({
    required this.params,
    required this.fed,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bitcoinDisplay = context.select<PreferencesProvider, BitcoinDisplay>(
      (prefs) => prefs.bitcoinDisplay,
    );
    final isFixed = params.minWithdrawableMsats == params.maxWithdrawableMsats;
    final amountLabel =
        isFixed
            ? context.l10n.lnurlWithdrawFixedAmount(
              formatBalance(params.maxWithdrawableMsats, false, bitcoinDisplay),
            )
            : context.l10n.lnurlWithdrawAmountRange(
              formatBalance(params.minWithdrawableMsats, false, bitcoinDisplay),
              formatBalance(params.maxWithdrawableMsats, false, bitcoinDisplay),
            );

    return Animate(
      effects: [FadeEffect(duration: 300.ms)],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 16),
          Icon(Icons.nfc, size: 64, color: theme.colorScheme.primary),
          const SizedBox(height: 24),
          if (params.defaultDescription.isNotEmpty) ...[
            Text(
              params.defaultDescription,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
          ],
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: theme.colorScheme.primary.withValues(alpha: 0.4),
              ),
            ),
            child: Text(
              amountLabel,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurface,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          const Spacer(),
          FilledButton(
            onPressed: onConfirm,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              textStyle: const TextStyle(fontSize: 18),
            ),
            child: Text(context.l10n.lnurlWithdrawConfirm),
          ),
        ],
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
