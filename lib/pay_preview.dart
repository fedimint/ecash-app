import 'package:ecashapp/db.dart';
import 'package:ecashapp/detail_row.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/providers/preferences_provider.dart';
import 'package:ecashapp/send.dart';
import 'package:ecashapp/utils.dart';
import 'package:ecashapp/utils/pin_guard.dart';
import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class PaymentPreviewWidget extends StatefulWidget {
  final FederationSelector fed;
  final PaymentPreviewWithGateways previewData;

  const PaymentPreviewWidget({
    super.key,
    required this.fed,
    required this.previewData,
  });

  @override
  State<PaymentPreviewWidget> createState() => _PaymentPreviewWidgetState();
}

class _PaymentPreviewWidgetState extends State<PaymentPreviewWidget> {
  late int _selectedIndex;

  @override
  void initState() {
    super.initState();
    _selectedIndex = widget.previewData.selectedIndex.toInt();
  }

  GatewayPaymentPreview get _selectedPreview =>
      widget.previewData.gatewayPreviews[_selectedIndex];

  bool get _hasMultipleGateways =>
      widget.previewData.gatewayPreviews.length > 1;

  String _gatewayDisplayName(FedimintGateway gw) {
    return gw.lightningAlias ?? gw.endpoint;
  }

  void _showGatewayPicker(BuildContext context) {
    final theme = Theme.of(context);
    final bitcoinDisplay = context.read<PreferencesProvider>().bitcoinDisplay;
    final gateways = widget.previewData.gatewayPreviews;

    showModalBottomSheet(
      context: context,
      backgroundColor: theme.bottomSheetTheme.backgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
                child: Text(
                  context.l10n.selectGateway,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              ...List.generate(gateways.length, (index) {
                final preview = gateways[index];
                final gw = preview.gateway;
                final isSelected = index == _selectedIndex;

                return ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 4,
                  ),
                  leading: Icon(
                    Icons.device_hub,
                    color:
                        isSelected
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurface.withOpacity(0.5),
                  ),
                  title: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _gatewayDisplayName(gw),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontFamily: 'monospace',
                            fontWeight:
                                isSelected
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (gw.isLnv2)
                        Container(
                          margin: const EdgeInsets.only(left: 8),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            'LNv2',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                    ],
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (gw.lightningAlias != null)
                        Text(
                          gw.endpoint,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurface.withOpacity(0.4),
                            fontFamily: 'monospace',
                            fontSize: 11,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      Text(
                        '${context.l10n.txDetailFee}: ${formatBalance(preview.amountWithFees - widget.previewData.amountMsats, true, bitcoinDisplay)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface.withOpacity(0.6),
                        ),
                      ),
                    ],
                  ),
                  trailing:
                      isSelected
                          ? Icon(
                            Icons.check_circle,
                            color: theme.colorScheme.primary,
                          )
                          : null,
                  onTap: () {
                    setState(() {
                      _selectedIndex = index;
                    });
                    Navigator.pop(context);
                  },
                );
              }),
              const SizedBox(height: 12),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bitcoinDisplay = context.select<PreferencesProvider, BitcoinDisplay>(
      (prefs) => prefs.bitcoinDisplay,
    );
    final amount = widget.previewData.amountMsats;
    final amountWithFees = _selectedPreview.amountWithFees;
    final fees = amountWithFees - amount;
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
        // Gateway card
        GestureDetector(
          onTap:
              _hasMultipleGateways ? () => _showGatewayPicker(context) : null,
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
                      Text(
                        _gatewayDisplayName(selectedGateway),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
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
                value: widget.fed.federationName,
              ),
              CopyableDetailRow(
                label: context.l10n.txDetailAmount,
                value: formatBalance(amount, true, bitcoinDisplay),
              ),
              CopyableDetailRow(
                label: context.l10n.txDetailFees,
                value: formatBalance(fees, true, bitcoinDisplay),
              ),
              CopyableDetailRow(
                label: context.l10n.txDetailTotal,
                value: formatBalance(amountWithFees, true, bitcoinDisplay),
              ),
              CopyableDetailRow(
                label: context.l10n.txDetailPaymentHash,
                value: widget.previewData.paymentHash,
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
            onPressed: () async {
              final authorized = await checkSpendingPin(context);
              if (!authorized) return;
              if (!context.mounted) return;
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder:
                      (context) => SendPayment(
                        fed: widget.fed,
                        invoice: widget.previewData.invoice,
                        amountMsats: amount,
                        gateway: _selectedPreview.gateway.endpoint,
                        isLnv2: _selectedPreview.gateway.isLnv2,
                        amountMsatsWithFees: amountWithFees,
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
