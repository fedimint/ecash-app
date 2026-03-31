import 'package:ecashapp/db.dart';
import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/providers/preferences_provider.dart';
import 'package:ecashapp/toast.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

class FederationUtxoList extends StatefulWidget {
  final String? invite;
  final FederationSelector fed;
  final bool isFederationOnline;

  const FederationUtxoList({
    super.key,
    required this.invite,
    required this.fed,
    required this.isFederationOnline,
  });

  @override
  State<FederationUtxoList> createState() => _FederationUtxoListState();
}

class _FederationUtxoListState extends State<FederationUtxoList> {
  List<Utxo>? utxos;

  @override
  void initState() {
    super.initState();
    _loadWalletSummary();
  }

  Future<void> _loadWalletSummary() async {
    if (widget.isFederationOnline) {
      try {
        final summary = await walletSummary(
          invite: widget.invite,
          federationId: widget.fed.federationId,
        );
        setState(() {
          utxos = summary;
        });
      } catch (e) {
        AppLogger.instance.error("Could not load wallet summary: $e");
        if (mounted) {
          ToastService().show(
            message: context.l10n.couldNotLoadUtxos,
            duration: const Duration(seconds: 5),
            onTap: () {},
            icon: Icon(Icons.error),
          );
        }
      }
    }
  }

  String abbreviateTxid(String txid, {int headLength = 8, int tailLength = 8}) {
    if (txid.length <= headLength + tailLength) return txid;
    final head = txid.substring(0, headLength);
    final tail = txid.substring(txid.length - tailLength);
    return '$head...$tail';
  }

  @override
  Widget build(BuildContext context) {
    final bitcoinDisplay = context.select<PreferencesProvider, BitcoinDisplay>(
      (prefs) => prefs.bitcoinDisplay,
    );

    if (!widget.isFederationOnline) {
      return Center(child: Text(context.l10n.cannotConnectForUtxos));
    }

    if (utxos == null) {
      return const Center(child: CircularProgressIndicator());
    }

    if (utxos!.isEmpty) {
      return Center(child: Text(context.l10n.noUtxosFound));
    }

    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: utxos!.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final utxo = utxos![index];
        final explorerUrl = explorerUrlForNetwork(
          utxo.txid,
          widget.fed.network,
        );
        final abbreviatedTxid = abbreviateTxid(utxo.txid);
        final txidLabel = "$abbreviatedTxid:${utxo.index}";

        return Container(
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A),
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      txidLabel,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 14,
                        color: Theme.of(context).colorScheme.primary,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: context.l10n.copyTxid,
                    icon: const Icon(Icons.copy),
                    color: Theme.of(context).colorScheme.secondary,
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: utxo.txid));
                      if (!context.mounted) return;
                      ToastService().show(
                        message: context.l10n.txidCopied(abbreviatedTxid),
                        duration: const Duration(seconds: 2),
                        onTap: () {},
                        icon: Icon(Icons.check),
                      );
                    },
                  ),
                  if (explorerUrl != null)
                    IconButton(
                      tooltip: context.l10n.viewOnMempoolSpace,
                      icon: const Icon(Icons.open_in_new),
                      color: Theme.of(context).colorScheme.secondary,
                      onPressed: () async {
                        final url = Uri.parse(explorerUrl);
                        await showExplorerConfirmation(context, url);
                      },
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                formatBalance(utxo.amount, false, bitcoinDisplay),
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
