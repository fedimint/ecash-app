import 'package:ecashapp/app.dart';
import '../constants/transaction_keys.dart';
import 'package:ecashapp/detail_row.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/redeem_ecash.dart';
import 'package:ecashapp/theme.dart';
import 'package:ecashapp/toast.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';

class TransactionDetails extends StatefulWidget {
  final Transaction tx;
  final Icon icon;
  final Map<String, String> details;
  final FederationSelector fed;

  const TransactionDetails({
    super.key,
    required this.tx,
    required this.icon,
    required this.details,
    required this.fed,
  });

  @override
  State<TransactionDetails> createState() => _TransactionDetailsState();
}

class _TransactionDetailsState extends State<TransactionDetails> {
  bool _checking = false;

  String _getTitleFromKind() {
    switch (widget.tx.kind) {
      case TransactionKind_LightningReceive():
        return "Lightning Receive";
      case TransactionKind_LightningSend():
        return "Lightning Send";
      case TransactionKind_LightningRecurring():
        return "Lightning Address Receive";
      case TransactionKind_EcashReceive():
        return "E-Cash Receive";
      case TransactionKind_EcashSend():
        return "E-Cash Send";
      case TransactionKind_OnchainReceive():
        return "Onchain Receive";
      case TransactionKind_OnchainSend():
        return "Onchain Send";
    }
  }

  Future<void> _checkClaimStatus() async {
    setState(() {
      _checking = true;
    });

    try {
      final ecash = widget.details[TransactionDetailKeys.ecash];
      if (ecash != null) {
        final result = await checkEcashSpent(
          federationId: widget.fed.federationId,
          ecash: ecash,
        );
        if (result) {
          ToastService().show(
            message: "This E-Cash has been claimed",
            duration: const Duration(seconds: 5),
            onTap: () {},
            icon: Icon(Icons.info),
          );
        } else {
          ToastService().show(
            message: "This E-Cash has not been claimed yet",
            duration: const Duration(seconds: 5),
            onTap: () {},
            icon: Icon(Icons.info),
          );
        }
      }
    } catch (e) {
      AppLogger.instance.error("Error checking claim status: $e");
      ToastService().show(
        message: "Unable to check E-Cash status",
        duration: const Duration(seconds: 5),
        onTap: () {},
        icon: Icon(Icons.error),
      );
    } finally {
      if (mounted) {
        setState(() {
          _checking = false;
        });
      }
    }
  }

  Future<void> _redeemEcash() async {
    final ecash = widget.details[TransactionDetailKeys.ecash];
    final amount = widget.tx.amount;

    if (ecash != null && amount > BigInt.zero) {
      final navigator = Navigator.of(context);
      navigator.pop();
      await Future.delayed(const Duration(milliseconds: 100));

      if (!mounted) return;

      invoicePaidToastVisible.value = false;
      await showAppModalBottomSheet(
        context: context,
        child: EcashRedeemPrompt(fed: widget.fed, ecash: ecash, amount: amount),
        heightFactor: 0.33,
      );
      invoicePaidToastVisible.value = true;
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
            Icon(widget.icon.icon, color: theme.colorScheme.primary, size: 24),
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
            children:
                widget.details.entries.map((entry) {
                  final abbreviate = entry.key == TransactionDetailKeys.ecash;

                  if (entry.key == TransactionDetailKeys.txid) {
                    String? txid;
                    switch (widget.tx.kind) {
                      case TransactionKind_OnchainSend(txid: final id):
                        txid = id;
                        break;
                      case TransactionKind_OnchainReceive(txid: final id):
                        txid = id;
                        break;
                      default:
                        break;
                    }

                    final explorerUrl =
                        txid != null
                            ? explorerUrlForNetwork(txid, widget.fed.network)
                            : null;

                    return CopyableDetailRow(
                      label: entry.key,
                      value: entry.value,
                      abbreviate: abbreviate,
                      additionalAction:
                          explorerUrl != null
                              ? Padding(
                                padding: const EdgeInsets.only(left: 8),
                                child: IconButton(
                                  tooltip: 'View on Block Explorer',
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
                    label: entry.key,
                    value: entry.value,
                    abbreviate: abbreviate,
                  );
                }).toList(),
          ),
        ),
        if (widget.tx.kind is TransactionKind_EcashSend) ...[
          const SizedBox(height: 24),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ElevatedButton(
                onPressed: _checking ? null : _checkClaimStatus,
                style: ElevatedButton.styleFrom(
                  backgroundColor: theme.colorScheme.primary,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child:
                    _checking
                        ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              Colors.black,
                            ),
                          ),
                        )
                        : const Text("Check Claim Status"),
              ),
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: _redeemEcash,
                style: OutlinedButton.styleFrom(
                  foregroundColor: theme.colorScheme.primary,
                  side: BorderSide(color: theme.colorScheme.primary),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text("Redeem Ecash"),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
