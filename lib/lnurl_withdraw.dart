import 'dart:async';

import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/success.dart';
import 'package:ecashapp/toast.dart';
import 'package:ecashapp/utils.dart';
import 'package:ecashapp/widgets/gateway_picker.dart'; // showGatewayPickerSheet
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';

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
  List<FedimintGateway> _gateways = [];
  FedimintGateway? _selectedGateway;
  BigInt _selectedAmountMsats = BigInt.zero;

  @override
  void initState() {
    super.initState();
    _fetchParams();
  }

  Future<void> _fetchParams() async {
    try {
      final results = await Future.wait([
        fetchLnurlWithdraw(url: widget.url),
        listGateways(federationId: widget.fed.federationId),
      ]);
      if (!mounted) return;
      final params = results[0] as LnurlWithdrawParams;
      final gateways = results[1] as List<FedimintGateway>;
      setState(() {
        _params = params;
        _gateways = gateways;
        _selectedGateway = gateways.isNotEmpty ? gateways.first : null;
        _selectedAmountMsats = params.maxWithdrawableMsats;
        _state = _WithdrawState.showingDetails;
      });
    } catch (e) {
      AppLogger.instance.error('Failed to fetch LNURLw params: $e');
      if (!mounted) return;
      _showErrorAndPop(e.toString());
    }
  }

  Future<void> _onGatewayTapped() async {
    if (_gateways.isEmpty) return;
    final currentIndex = _gateways.indexOf(_selectedGateway ?? _gateways.first);
    final pickedIndex = await showGatewayPickerSheet(
      context,
      gateways: _gateways,
      selectedIndex: currentIndex >= 0 ? currentIndex : 0,
    );
    if (pickedIndex != null && mounted) {
      setState(() => _selectedGateway = _gateways[pickedIndex]);
    }
  }

  Future<void> _onConfirm() async {
    final params = _params!;
    final gateway = _selectedGateway;
    if (gateway == null) {
      _showErrorAndPop('No gateway available');
      return;
    }
    setState(() => _state = _WithdrawState.executing);

    final requestedMsats = _selectedAmountMsats;
    final receiveAmount = await computeReceiveAmountWithFees(
      federationId: widget.fed.federationId,
      gatewayUrl: gateway.endpoint,
      isLnv2: gateway.isLnv2,
      amountMsats: requestedMsats,
      includeFees: false,
    );

    OperationId opId;
    try {
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
              selectedAmountMsats: _selectedAmountMsats,
              onAmountChanged: (v) => setState(() => _selectedAmountMsats = v),
              selectedGateway: _selectedGateway,
              hasMultipleGateways: _gateways.length > 1,
              onGatewayTapped: _onGatewayTapped,
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

class _DetailsView extends StatefulWidget {
  final LnurlWithdrawParams params;
  final FederationSelector fed;
  final BigInt selectedAmountMsats;
  final ValueChanged<BigInt> onAmountChanged;
  final FedimintGateway? selectedGateway;
  final bool hasMultipleGateways;
  final VoidCallback onGatewayTapped;
  final VoidCallback onConfirm;

  const _DetailsView({
    required this.params,
    required this.fed,
    required this.selectedAmountMsats,
    required this.onAmountChanged,
    required this.selectedGateway,
    required this.hasMultipleGateways,
    required this.onGatewayTapped,
    required this.onConfirm,
  });

  @override
  State<_DetailsView> createState() => _DetailsViewState();
}

class _DetailsViewState extends State<_DetailsView> {
  late final TextEditingController _amountController;
  String? _amountError;

  BigInt get _minSats =>
      widget.params.minWithdrawableMsats ~/ BigInt.from(1000);
  BigInt get _maxSats =>
      widget.params.maxWithdrawableMsats ~/ BigInt.from(1000);

  @override
  void initState() {
    super.initState();
    final initialSats = widget.selectedAmountMsats ~/ BigInt.from(1000);
    _amountController = TextEditingController(text: initialSats.toString());
  }

  @override
  void dispose() {
    _amountController.dispose();
    super.dispose();
  }

  void _onAmountChanged(String raw) {
    final sats = BigInt.tryParse(raw);
    if (sats == null || raw.isEmpty) {
      setState(() => _amountError = null);
      return;
    }
    if (sats < _minSats) {
      setState(() => _amountError = 'Min $_minSats sats');
      return;
    }
    if (sats > _maxSats) {
      setState(() => _amountError = 'Max $_maxSats sats');
      widget.onAmountChanged(widget.params.maxWithdrawableMsats);
      return;
    }
    setState(() => _amountError = null);
    widget.onAmountChanged(sats * BigInt.from(1000));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isFixed =
        widget.params.minWithdrawableMsats ==
        widget.params.maxWithdrawableMsats;

    return Animate(
      effects: [FadeEffect(duration: 300.ms)],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 16),
          Icon(Icons.nfc, size: 64, color: theme.colorScheme.primary),
          const SizedBox(height: 24),
          if (widget.params.defaultDescription.isNotEmpty) ...[
            Text(
              widget.params.defaultDescription,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
          ],
          if (isFixed)
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
                '$_maxSats sats',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
            )
          else ...[
            TextField(
              controller: _amountController,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
              decoration: InputDecoration(
                suffixText: 'sats',
                errorText: _amountError,
                helperText: 'Min: $_minSats – Max: $_maxSats sats',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 16,
                ),
              ),
              onChanged: _onAmountChanged,
            ),
          ],
          if (widget.selectedGateway != null) ...[
            const SizedBox(height: 12),
            InkWell(
              onTap: widget.hasMultipleGateways ? widget.onGatewayTapped : null,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: theme.colorScheme.primary.withValues(alpha: 0.1),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.device_hub,
                      color: theme.colorScheme.primary,
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        widget.selectedGateway!.lightningAlias ??
                            widget.selectedGateway!.endpoint,
                        style: theme.textTheme.bodyMedium,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (widget.hasMultipleGateways)
                      Icon(
                        Icons.unfold_more,
                        color: Colors.grey[500],
                        size: 18,
                      ),
                  ],
                ),
              ),
            ),
          ],
          const Spacer(),
          FilledButton(
            onPressed: _amountError == null ? widget.onConfirm : null,
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
