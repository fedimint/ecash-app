import 'package:carbine/detail_row.dart';
import 'package:carbine/multimint.dart';
import 'package:flutter/material.dart';

class TransactionDetails extends StatelessWidget {
  final TransactionKind kind;
  final Icon icon;
  final Map<String, String> details;

  const TransactionDetails({
    super.key,
    required this.kind,
    required this.icon,
    required this.details,
  });

  String _getTitleFromKind() {
    switch (kind) {
      case TransactionKind_LightningReceive():
        return "Lightning Receive";
      case TransactionKind_LightningSend():
        return "Lightning Send";
      case TransactionKind_EcashReceive():
        return "Ecash Receive";
      case TransactionKind_EcashSend():
        return "Ecash Send";
      case TransactionKind_OnchainReceive():
        return "Onchain Receive";
      case TransactionKind_OnchainSend():
        return "Onchain Send";
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              icon.icon,
              color: theme.colorScheme.primary,
              size: 24,
            ),
            const SizedBox(width: 8),
            Text(
              _getTitleFromKind(),
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.primary,
              ),
            ),
          ],
        ),
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
            children: details.entries.map((entry) {
              return CopyableDetailRow(
                label: entry.key,
                value: entry.value,
              );
            }).toList(),
          ),
        ),
      ],
    );
  }
}

