import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/widgets/protocol_badge.dart';
import 'package:flutter/material.dart';

/// A one-line summary of the selected gateway (alias + protocol badge), shown
/// in the federation card on the amount screen.
///
/// [gateways] is `null` while the list is loading (renders a spinner) and
/// empty when none are available.
class GatewaySummaryLine extends StatelessWidget {
  final List<FedimintGateway>? gateways;
  final FedimintGateway? selectedGateway;

  const GatewaySummaryLine({
    super.key,
    required this.gateways,
    required this.selectedGateway,
  });

  @override
  Widget build(BuildContext context) {
    final selected = selectedGateway;

    final Widget content;
    if (gateways == null) {
      content = const SizedBox(
        width: 12,
        height: 12,
        child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.grey),
      );
    } else if (selected == null) {
      content = Text(
        context.l10n.noGatewaysAvailableShort,
        style: const TextStyle(fontSize: 12, color: Colors.grey),
      );
    } else {
      content = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              selected.lightningAlias ?? selected.endpoint,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 6),
          ProtocolBadge(isLnv2: selected.isLnv2),
        ],
      );
    }

    return Row(
      children: [
        const Icon(Icons.device_hub, size: 14, color: Colors.grey),
        const SizedBox(width: 6),
        Flexible(child: content),
      ],
    );
  }
}
