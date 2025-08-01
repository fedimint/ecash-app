import 'package:ecashapp/detail_row.dart';
import 'package:ecashapp/multimint.dart';
import 'package:flutter/material.dart';
import 'package:ecashapp/utils.dart';
import 'package:url_launcher/url_launcher.dart';

class GatewayDetailsSheet extends StatelessWidget {
  final FedimintGateway gateway;

  const GatewayDetailsSheet({super.key, required this.gateway});

  void _launchAmboss(String nodeId) async {
    final url = Uri.parse('https://amboss.space/node/$nodeId');
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          "Lightning Gateway",
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.bold,
            color: theme.colorScheme.primary,
          ),
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
            children: [
              CopyableDetailRow(label: 'Endpoint', value: gateway.endpoint),
              CopyableDetailRow(
                label: 'Routing Fee',
                value: "${formatBalance(gateway.baseRoutingFee, true)} + ${gateway.ppmRoutingFee} ppm",
              ),
              CopyableDetailRow(
                label: 'Transaction Fee',
                value: "${formatBalance(gateway.baseTransactionFee, true)} + ${gateway.ppmTransactionFee} ppm",
              ),
              if (gateway.lightningAlias != null)
                CopyableDetailRow(label: 'Lightning Alias', value: gateway.lightningAlias!),
              if (gateway.lightningNode != null) ...[
                CopyableDetailRow(label: 'Node Public Key', value: gateway.lightningNode!),
                const SizedBox(height: 4),
                GestureDetector(
                  onTap: () => _launchAmboss(gateway.lightningNode!),
                  child: Text(
                    "View on Amboss",
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.secondary,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}


