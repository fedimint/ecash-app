import 'package:ecashapp/db.dart';
import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/providers/preferences_provider.dart';
import 'package:ecashapp/utils.dart';
import 'package:ecashapp/widgets/protocol_badge.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// A gateway summary card showing the selected gateway's alias, protocol badge
/// and routing fee.
///
/// [gateways] is `null` while the list is loading (renders a spinner), empty
/// when none are available, otherwise [selectedGateway] is shown. When there is
/// at least one gateway and [onTap] is non-null the card is interactive and
/// shows a chevron to open a gateway picker. Shared by the amount screen
/// (`number_pad.dart`) and the LNURLw withdraw screen.
class GatewayCard extends StatelessWidget {
  final List<FedimintGateway>? gateways;
  final FedimintGateway? selectedGateway;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry margin;

  const GatewayCard({
    super.key,
    required this.gateways,
    required this.selectedGateway,
    this.onTap,
    this.margin = const EdgeInsets.fromLTRB(16, 16, 16, 12),
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bitcoinDisplay = context.select<PreferencesProvider, BitcoinDisplay>(
      (prefs) => prefs.bitcoinDisplay,
    );
    final gws = gateways;
    final selected = selectedGateway;
    final canTap = gws != null && gws.isNotEmpty && onTap != null;

    return Center(
      child: GestureDetector(
        onTap: canTap ? onTap : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          constraints: const BoxConstraints(maxWidth: 400),
          margin: margin,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: theme.colorScheme.primary.withValues(alpha: 0.1),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
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
                size: 28,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      context.l10n.gateway,
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                    const SizedBox(height: 4),
                    if (gws == null)
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.grey,
                        ),
                      )
                    else if (selected == null)
                      Text(
                        context.l10n.noGatewaysAvailableShort,
                        style: const TextStyle(
                          fontSize: 14,
                          color: Colors.grey,
                        ),
                      )
                    else ...[
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              selected.lightningAlias ?? selected.endpoint,
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          ProtocolBadge(isLnv2: selected.isLnv2),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${formatBalance(selected.baseRoutingFee, true, bitcoinDisplay)} + ${selected.ppmRoutingFee} ppm',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (canTap)
                Icon(Icons.unfold_more, color: Colors.grey[500], size: 20),
            ],
          ),
        ),
      ),
    );
  }
}
