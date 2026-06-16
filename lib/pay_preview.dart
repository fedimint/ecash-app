import 'package:ecashapp/db.dart';
import 'package:ecashapp/detail_row.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/providers/preferences_provider.dart';
import 'package:ecashapp/send.dart';
import 'package:ecashapp/toast.dart';
import 'package:ecashapp/utils.dart';
import 'package:ecashapp/utils/pin_guard.dart';
import 'package:ecashapp/widgets/federation_picker.dart';
import 'package:ecashapp/widgets/gateway_picker.dart';
import 'package:ecashapp/widgets/protocol_badge.dart';
import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class PaymentPreviewWidget extends StatefulWidget {
  final FederationSelector fed;
  final PaymentPreviewWithGateways previewData;
  final List<(FederationSelector, bool)> federations;

  const PaymentPreviewWidget({
    super.key,
    required this.fed,
    required this.previewData,
    required this.federations,
  });

  @override
  State<PaymentPreviewWidget> createState() => _PaymentPreviewWidgetState();
}

class _PaymentPreviewWidgetState extends State<PaymentPreviewWidget> {
  late int _selectedIndex;
  late FederationSelector _selectedFed;
  late PaymentPreviewWithGateways _previewData;
  late String _invoice;
  bool _reloadingPreview = false;

  @override
  void initState() {
    super.initState();
    _selectedFed = widget.fed;
    _previewData = widget.previewData;
    _invoice = widget.previewData.invoice;
    _selectedIndex = widget.previewData.selectedIndex.toInt();
  }

  GatewayPaymentPreview get _selectedPreview =>
      _previewData.gatewayPreviews[_selectedIndex];

  bool get _hasMultipleGateways => _previewData.gatewayPreviews.length > 1;

  List<(FederationSelector, bool)> get _compatibleFederations =>
      widget.federations
          .where((entry) => entry.$1.network == _previewData.network)
          .toList();

  bool get _hasMultipleFederations => _compatibleFederations.length > 1;

  String _gatewayDisplayName(FedimintGateway gw) {
    return gw.lightningAlias ?? gw.endpoint;
  }

  Future<void> _showGatewayPicker(BuildContext context) async {
    final picked = await showGatewayPickerSheetFromPreviews(
      context,
      previews: _previewData.gatewayPreviews,
      invoiceAmountMsats: _previewData.amountMsats,
      selectedIndex: _selectedIndex,
    );
    if (picked != null && picked != _selectedIndex) {
      setState(() {
        _selectedIndex = picked;
      });
    }
  }

  Future<void> _showFederationPicker(BuildContext context) async {
    final picked = await showFederationPicker(
      context: context,
      federations: _compatibleFederations,
      title: context.l10n.selectFederationToPayFrom,
    );
    if (picked == null || !mounted) return;
    final (newFed, recovering) = picked;
    if (recovering) return;
    if (newFed.federationId == _selectedFed.federationId) return;

    setState(() {
      _selectedFed = newFed;
      _reloadingPreview = true;
    });
    try {
      final newPreview = await paymentPreviewWithGateways(
        federationId: newFed.federationId,
        bolt11: _invoice,
      );
      if (!mounted) return;
      setState(() {
        _previewData = newPreview;
        _selectedIndex = newPreview.selectedIndex.toInt();
        _reloadingPreview = false;
      });
    } catch (e) {
      AppLogger.instance.warn(
        'Failed to refetch preview for new federation: $e',
      );
      if (!mounted) return;
      setState(() => _reloadingPreview = false);
      ToastService().show(
        message: context.l10n.couldNotGetLightningPaymentDetails,
        duration: const Duration(seconds: 5),
        onTap: () {},
        icon: const Icon(Icons.error),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bitcoinDisplay = context.select<PreferencesProvider, BitcoinDisplay>(
      (prefs) => prefs.bitcoinDisplay,
    );
    final amount = _previewData.amountMsats;
    final amountWithFees = _selectedPreview.amountWithFees;
    final federationFee = _selectedPreview.federationFee;
    final gatewayFee = _selectedPreview.gatewayFee;
    final selectedGateway = _selectedPreview.gateway;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.l10n.confirmLightningPayment,
          style: theme.textTheme.headlineSmall?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 16),
        // Federation card
        GestureDetector(
          onTap:
              _hasMultipleFederations && !_reloadingPreview
                  ? () => _showFederationPicker(context)
                  : null,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: theme.colorScheme.primary.withOpacity(0.1),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.3),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Row(
              children: [
                Icon(
                  Icons.account_balance,
                  color: theme.colorScheme.primary,
                  size: 24,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.l10n.payerFederation,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface.withOpacity(0.6),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _selectedFed.federationName,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (_hasMultipleFederations)
                  Icon(
                    Icons.swap_horiz,
                    color: theme.colorScheme.primary,
                    size: 20,
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        // Gateway card
        GestureDetector(
          onTap:
              _hasMultipleGateways && !_reloadingPreview
                  ? () => _showGatewayPicker(context)
                  : null,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: theme.colorScheme.primary.withOpacity(0.1),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.3),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Row(
              children: [
                Icon(
                  Icons.device_hub,
                  color: theme.colorScheme.primary,
                  size: 24,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.l10n.gateway,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface.withOpacity(0.6),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              _gatewayDisplayName(selectedGateway),
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          ProtocolBadge(isLnv2: selectedGateway.isLnv2),
                        ],
                      ),
                      if (selectedGateway.lightningAlias != null)
                        Text(
                          selectedGateway.endpoint,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurface.withOpacity(0.5),
                            fontFamily: 'monospace',
                            fontSize: 11,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                if (_hasMultipleGateways)
                  Icon(
                    Icons.swap_horiz,
                    color: theme.colorScheme.primary,
                    size: 20,
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainer,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: theme.colorScheme.primary.withOpacity(0.25),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CopyableDetailRow(
                label: context.l10n.payerFederation,
                value: _selectedFed.federationName,
              ),
              CopyableDetailRow(
                label: context.l10n.txDetailAmount,
                value: formatBalance(amount, true, bitcoinDisplay),
              ),
              if (federationFee > BigInt.zero)
                CopyableDetailRow(
                  label: context.l10n.txDetailFederationFee,
                  value: formatBalance(federationFee, true, bitcoinDisplay),
                ),
              if (gatewayFee > BigInt.zero)
                CopyableDetailRow(
                  label: context.l10n.txDetailGatewayFee,
                  value: formatBalance(gatewayFee, true, bitcoinDisplay),
                ),
              CopyableDetailRow(
                label: context.l10n.txDetailTotal,
                value: formatBalance(amountWithFees, true, bitcoinDisplay),
              ),
              CopyableDetailRow(
                label: context.l10n.txDetailPaymentHash,
                value: _previewData.paymentHash,
              ),
            ],
          ),
        ),
        const SizedBox(height: 32),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            icon: const Icon(Icons.send, color: Colors.black),
            label: Text(context.l10n.sendPayment),
            style: ElevatedButton.styleFrom(
              backgroundColor: theme.colorScheme.primary,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            onPressed:
                _reloadingPreview
                    ? null
                    : () async {
                      final authorized = await checkSpendingPin(context);
                      if (!authorized) return;
                      if (!context.mounted) return;
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder:
                              (context) => SendPayment(
                                fed: _selectedFed,
                                invoice: _previewData.invoice,
                                amountMsats: amount,
                                gateway: _selectedPreview.gateway.endpoint,
                                isLnv2: _selectedPreview.gateway.isLnv2,
                                amountMsatsWithFees: amountWithFees,
                                federationFeeMsats: federationFee,
                                gatewayFeeMsats: gatewayFee,
                              ),
                        ),
                      );
                    },
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}
