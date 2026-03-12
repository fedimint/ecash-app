import 'package:ecashapp/db.dart';
import 'package:ecashapp/detail_row.dart';
import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/providers/preferences_provider.dart';
import 'package:flutter/material.dart';
import 'package:ecashapp/utils.dart';
import 'package:provider/provider.dart';
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
    final bitcoinDisplay = context.select<PreferencesProvider, BitcoinDisplay>(
      (prefs) => prefs.bitcoinDisplay,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.l10n.lightningGateway,
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
              CopyableDetailRow(
                label: context.l10n.endpointLabel,
                value: gateway.endpoint,
              ),
              CopyableDetailRow(
                label: context.l10n.routingFee,
                value:
                    "${formatBalance(gateway.baseRoutingFee, true, bitcoinDisplay)} + ${gateway.ppmRoutingFee} ppm",
              ),
              CopyableDetailRow(
                label: context.l10n.transactionFee,
                value:
                    "${formatBalance(gateway.baseTransactionFee, true, bitcoinDisplay)} + ${gateway.ppmTransactionFee} ppm",
              ),
              if (gateway.lightningAlias != null)
                CopyableDetailRow(
                  label: context.l10n.lightningAliasLabel,
                  value: gateway.lightningAlias!,
                ),
              if (gateway.lightningNode != null) ...[
                CopyableDetailRow(
                  label: context.l10n.nodePublicKey,
                  value: gateway.lightningNode!,
                ),
                const SizedBox(height: 4),
                GestureDetector(
                  onTap: () => _launchAmboss(gateway.lightningNode!),
                  child: Text(
                    context.l10n.viewOnAmboss,
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
