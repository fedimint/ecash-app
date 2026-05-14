import 'package:ecashapp/db.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/providers/preferences_provider.dart';
import 'package:ecashapp/utils.dart';
import 'package:ecashapp/widgets/protocol_badge.dart';
import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// A list of selectable gateways.
///
/// When [feesMsats] is provided, each tile displays the fee as an absolute
/// amount (e.g. "Fee: 1 sat"). When omitted, tiles fall back to the gateway's
/// advertised routing fee in `base + ppm` form (e.g. "0 sat + 100 ppm").
class GatewayPicker extends StatelessWidget {
  final List<FedimintGateway> gateways;
  final List<BigInt>? feesMsats;
  final int? selectedIndex;
  final ValueChanged<int>? onSelected;

  const GatewayPicker({
    super.key,
    required this.gateways,
    this.feesMsats,
    this.selectedIndex,
    this.onSelected,
  }) : assert(feesMsats == null || feesMsats.length == gateways.length);

  /// Build a picker from a list of [GatewayPaymentPreview]s, computing each
  /// gateway's fee as `amountWithFees - invoiceAmountMsats`.
  GatewayPicker.fromPreviews({
    Key? key,
    required List<GatewayPaymentPreview> previews,
    required BigInt invoiceAmountMsats,
    int? selectedIndex,
    ValueChanged<int>? onSelected,
  }) : this(
         key: key,
         gateways: previews.map((p) => p.gateway).toList(),
         feesMsats:
             previews
                 .map((p) => p.amountWithFees - invoiceAmountMsats)
                 .toList(),
         selectedIndex: selectedIndex,
         onSelected: onSelected,
       );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bitcoinDisplay = context.select<PreferencesProvider, BitcoinDisplay>(
      (prefs) => prefs.bitcoinDisplay,
    );

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
            final gw = gateways[index];
            final isSelected = index == selectedIndex;

            final feeText =
                feesMsats != null
                    ? '${context.l10n.txDetailFee}: ${formatBalance(feesMsats![index], true, bitcoinDisplay)}'
                    : '${formatBalance(gw.baseRoutingFee, true, bitcoinDisplay)} + ${gw.ppmRoutingFee} ppm';

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
                      gw.lightningAlias ?? gw.endpoint,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontFamily: 'monospace',
                        fontWeight:
                            isSelected ? FontWeight.bold : FontWeight.normal,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: ProtocolBadge(isLnv2: gw.isLnv2),
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
                    feeText,
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
              onTap: onSelected == null ? null : () => onSelected!(index),
            );
          }),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

/// Shows [GatewayPicker] in a modal bottom sheet and resolves with the tapped
/// index (or null if the sheet was dismissed without a selection).
Future<int?> showGatewayPickerSheet(
  BuildContext context, {
  required List<FedimintGateway> gateways,
  List<BigInt>? feesMsats,
  int? selectedIndex,
}) {
  final theme = Theme.of(context);
  return showModalBottomSheet<int>(
    context: context,
    backgroundColor: theme.bottomSheetTheme.backgroundColor,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (context) {
      return GatewayPicker(
        gateways: gateways,
        feesMsats: feesMsats,
        selectedIndex: selectedIndex,
        onSelected: (i) => Navigator.pop(context, i),
      );
    },
  );
}

/// Convenience wrapper around [showGatewayPickerSheet] that takes a list of
/// [GatewayPaymentPreview]s and an invoice amount.
Future<int?> showGatewayPickerSheetFromPreviews(
  BuildContext context, {
  required List<GatewayPaymentPreview> previews,
  required BigInt invoiceAmountMsats,
  int? selectedIndex,
}) {
  return showGatewayPickerSheet(
    context,
    gateways: previews.map((p) => p.gateway).toList(),
    feesMsats:
        previews.map((p) => p.amountWithFees - invoiceAmountMsats).toList(),
    selectedIndex: selectedIndex,
  );
}
