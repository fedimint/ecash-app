import 'dart:async';

import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/success.dart';
import 'package:ecashapp/toast.dart';
import 'package:ecashapp/utils.dart';
import 'package:ecashapp/widgets/federation_card.dart';
import 'package:ecashapp/widgets/federation_picker.dart'; // showFederationPicker
import 'package:ecashapp/widgets/gateway_card.dart';
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

  // The federation the withdraw lands in determines the network of the invoice
  // we generate, so it must be user-selectable.
  late FederationSelector _selectedFed;
  List<(FederationSelector, bool)> _allFederations = [];
  FederationMeta? _federationMeta;
  BigInt? _balanceMsats;

  // `null` while gateways are loading for the selected federation.
  List<FedimintGateway>? _gateways;
  FedimintGateway? _selectedGateway;
  BigInt _selectedAmountMsats = BigInt.zero;

  @override
  void initState() {
    super.initState();
    _selectedFed = widget.fed;
    _fetchInitial();
  }

  Future<void> _fetchInitial() async {
    try {
      final results = await Future.wait([
        fetchLnurlWithdraw(url: widget.url),
        federations(),
      ]);
      if (!mounted) return;
      final params = results[0] as LnurlWithdrawParams;
      final allFeds = results[1] as List<(FederationSelector, bool)>;
      setState(() {
        _params = params;
        _allFederations = allFeds;
        _selectedAmountMsats = params.maxWithdrawableMsats;
        _state = _WithdrawState.showingDetails;
      });
      _loadFederationData();
    } catch (e) {
      AppLogger.instance.error('Failed to fetch LNURLw params: $e');
      if (!mounted) return;
      _showErrorAndPop(e.toString());
    }
  }

  /// Load gateways, metadata (for the picture) and balance for the currently
  /// selected federation. Called on first load and whenever the federation
  /// changes.
  Future<void> _loadFederationData() async {
    // `_selectedFed.federationId` is an opaque FFI handle that is consumed when
    // passed across the bridge, so re-read it from `_selectedFed` for every
    // call rather than caching it in a local — reusing one handle throws
    // DroppableDisposedException on the second use.
    try {
      final gws = await listGateways(federationId: _selectedFed.federationId);
      if (!mounted) return;
      setState(() {
        _gateways = gws;
        _selectedGateway = gws.isNotEmpty ? gws.first : null;
      });
    } catch (e) {
      AppLogger.instance.error('Failed to list gateways: $e');
      if (!mounted) return;
      setState(() {
        _gateways = const [];
        _selectedGateway = null;
      });
    }

    // Picture and balance are best-effort cosmetics for the federation card.
    try {
      final meta = await getFederationMeta(
        federationId: _selectedFed.federationId,
      );
      if (mounted) setState(() => _federationMeta = meta);
    } catch (e) {
      AppLogger.instance.error('Failed to fetch federation meta: $e');
    }
    try {
      final bal = await balance(federationId: _selectedFed.federationId);
      if (mounted) setState(() => _balanceMsats = bal);
    } catch (e) {
      AppLogger.instance.error('Failed to fetch balance: $e');
    }
  }

  Future<void> _onFederationCardTapped() async {
    if (_allFederations.length <= 1) return;
    final selected = await showFederationPicker(
      context: context,
      federations: _allFederations,
      title: context.l10n.selectMint,
    );
    if (selected == null || !mounted) return;
    setState(() {
      _selectedFed = selected.$1;
      _federationMeta = null;
      _balanceMsats = null;
      _gateways = null;
      _selectedGateway = null;
    });
    _loadFederationData();
  }

  Future<void> _onGatewayCardTapped() async {
    final gateways = _gateways;
    if (gateways == null || gateways.isEmpty) return;
    final currentIndex = gateways.indexOf(_selectedGateway ?? gateways.first);
    final pickedIndex = await showGatewayPickerSheet(
      context,
      gateways: gateways,
      selectedIndex: currentIndex >= 0 ? currentIndex : 0,
    );
    if (pickedIndex != null && mounted) {
      setState(() => _selectedGateway = gateways[pickedIndex]);
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
      federationId: _selectedFed.federationId,
      gatewayUrl: gateway.endpoint,
      isLnv2: gateway.isLnv2,
      amountMsats: requestedMsats,
      includeFees: false,
    );

    OperationId opId;
    try {
      opId = await executeLnurlWithdraw(
        federationId: _selectedFed.federationId,
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
        federationId: _selectedFed.federationId,
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
              selectedAmountMsats: _selectedAmountMsats,
              onAmountChanged: (v) => setState(() => _selectedAmountMsats = v),
              federationCard: FederationCard(
                federation: _selectedFed,
                pictureUrl: _federationMeta?.picture,
                balanceMsats: _balanceMsats,
                onTap:
                    _allFederations.length > 1 ? _onFederationCardTapped : null,
                margin: const EdgeInsets.only(bottom: 12),
              ),
              gatewayCard: GatewayCard(
                gateways: _gateways,
                selectedGateway: _selectedGateway,
                onTap: _onGatewayCardTapped,
                margin: const EdgeInsets.only(bottom: 12),
              ),
              confirmEnabled: _selectedGateway != null,
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
  final BigInt selectedAmountMsats;
  final ValueChanged<BigInt> onAmountChanged;
  final Widget federationCard;
  final Widget gatewayCard;
  final bool confirmEnabled;
  final VoidCallback onConfirm;

  const _DetailsView({
    required this.params,
    required this.selectedAmountMsats,
    required this.onAmountChanged,
    required this.federationCard,
    required this.gatewayCard,
    required this.confirmEnabled,
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
          const SizedBox(height: 8),
          Icon(Icons.nfc, size: 64, color: theme.colorScheme.primary),
          const SizedBox(height: 16),
          // Static, app-controlled copy — never render the description text
          // supplied by the (untrusted) LNURL server.
          Text(
            context.l10n.lnurlWithdrawDescription,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
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
          const SizedBox(height: 16),
          widget.federationCard,
          widget.gatewayCard,
          const Spacer(),
          FilledButton(
            onPressed:
                (widget.confirmEnabled && _amountError == null)
                    ? widget.onConfirm
                    : null,
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
