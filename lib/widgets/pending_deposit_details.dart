import 'package:ecashapp/constants/transaction_key_labels.dart';
import 'package:ecashapp/constants/transaction_keys.dart';
import 'package:ecashapp/detail_row.dart';
import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';

class PendingDepositDetails extends StatelessWidget {
  final Icon icon;
  final String statusMessage;
  final Map<String, String> details;
  final String? txid;
  final FederationSelector fed;

  const PendingDepositDetails({
    super.key,
    required this.icon,
    required this.statusMessage,
    required this.details,
    required this.txid,
    required this.fed,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final explorerUrl =
        txid != null ? explorerUrlForNetwork(txid!, fed.network) : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon.icon, color: theme.colorScheme.primary, size: 24),
            const SizedBox(width: 8),
            Text(
              context.l10n.pendingReceive,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.primary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(statusMessage, style: theme.textTheme.bodyMedium),
        const SizedBox(height: 24),
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
            children:
                details.entries.map((entry) {
                  if (entry.key == TransactionDetailKeys.txid) {
                    return CopyableDetailRow(
                      label: localizedTxLabel(context.l10n, entry.key),
                      value: entry.value,
                      abbreviate: true,
                      additionalAction:
                          explorerUrl != null
                              ? Padding(
                                padding: const EdgeInsets.only(left: 8),
                                child: IconButton(
                                  tooltip: context.l10n.viewOnBlockExplorer,
                                  iconSize: 20,
                                  padding: EdgeInsets.zero,
                                  visualDensity: VisualDensity.compact,
                                  icon: Icon(
                                    Icons.open_in_new,
                                    color: theme.colorScheme.secondary,
                                  ),
                                  onPressed:
                                      () async =>
                                          await showExplorerConfirmation(
                                            context,
                                            Uri.parse(explorerUrl),
                                          ),
                                ),
                              )
                              : null,
                    );
                  }

                  return CopyableDetailRow(
                    label: localizedTxLabel(context.l10n, entry.key),
                    value: entry.value,
                  );
                }).toList(),
          ),
        ),
      ],
    );
  }
}
