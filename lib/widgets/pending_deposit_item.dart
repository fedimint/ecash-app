import 'package:flutter/material.dart';
import 'package:ecashapp/constants/transaction_keys.dart';
import 'package:ecashapp/db.dart';
import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/providers/preferences_provider.dart';
import 'package:ecashapp/theme.dart';
import 'package:ecashapp/utils.dart';
import 'package:ecashapp/widgets/pending_deposit_details.dart';
import 'package:provider/provider.dart';

class PendingDepositItem extends StatelessWidget {
  final DepositEventKind event;
  final FederationSelector fed;

  const PendingDepositItem({super.key, required this.event, required this.fed});

  /// ppm → percentage: 10,000 ppm equals 1%. Mirrors the receive screen.
  String _formatRate(BigInt partsPerMillion) {
    final percent = partsPerMillion.toDouble() / 10000.0;
    return '${percent.toStringAsFixed(2)}% ($partsPerMillion ppm)';
  }

  void _onTap(
    BuildContext context,
    String msg,
    BigInt amount,
    String? txid,
    BitcoinDisplay bitcoinDisplay,
  ) {
    // Resolved before the await below so the async builder never reaches back
    // into a BuildContext across an async gap.
    final noFeeConfigured = context.l10n.noFeeConfigured;
    showAppModalBottomSheet(
      context: context,
      childBuilder: () async {
        final feeQuote = await getPeginFeeQuote(federationId: fed.federationId);
        return PendingDepositDetails(
          icon: const Icon(Icons.link, color: Colors.yellowAccent),
          statusMessage: msg,
          txid: txid,
          fed: fed,
          details: {
            TransactionDetailKeys.amount: formatBalance(
              amount,
              false,
              bitcoinDisplay,
            ),
            if (txid != null) TransactionDetailKeys.txid: txid,
            // The peg-in fee has no single total: walletv2 scales the
            // federation fee with the deposit amount and adds a dynamic claim
            // fee, so surface the same components the receive screen does
            // rather than presenting a computed figure as authoritative.
            TransactionDetailKeys.federationBaseFee:
                feeQuote.baseFeeMsats == BigInt.zero
                    ? noFeeConfigured
                    : formatBalance(
                      feeQuote.baseFeeMsats,
                      false,
                      bitcoinDisplay,
                    ),
            if (feeQuote.partsPerMillion > BigInt.zero)
              TransactionDetailKeys.federationRate: _formatRate(
                feeQuote.partsPerMillion,
              ),
            if (feeQuote.onchainClaimFeeSats != null)
              TransactionDetailKeys.onchainClaimFee: formatBalance(
                feeQuote.onchainClaimFeeSats! * BigInt.from(1000),
                false,
                bitcoinDisplay,
              ),
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final bitcoinDisplay = context.select<PreferencesProvider, BitcoinDisplay>(
      (prefs) => prefs.bitcoinDisplay,
    );
    String msg;
    BigInt amount;
    String? txid;

    switch (event) {
      case DepositEventKind_Mempool(field0: final e):
        msg = context.l10n.txInMempool;
        amount = e.amount;
        txid = e.txid;
        break;
      case DepositEventKind_AwaitingConfs(field0: final e):
        // Once the tx is fully confirmed (0 confs left), the on-chain wait is
        // over and we're waiting on the ecash claim (for walletv2 this happens
        // in the background and isn't instant), so showing "0 confs left" would
        // be confusing.
        msg =
            e.needed == BigInt.zero
                ? context.l10n.txConfirmedClaimingEcash
                : context.l10n.txInBlockRemainingConfs(
                  e.blockHeight.toString(),
                  e.needed.toString(),
                );
        amount = e.amount;
        txid = e.txid;
        break;
      case DepositEventKind_Confirmed(field0: final e):
        msg = context.l10n.txConfirmedClaimingEcash;
        amount = e.amount;
        txid = e.txid;
        break;
      case DepositEventKind_Claimed():
        return const SizedBox.shrink();
    }

    final formatted = formatBalance(amount, false, bitcoinDisplay);
    final amountStyle = TextStyle(
      fontWeight: FontWeight.bold,
      color: Theme.of(context).colorScheme.primary,
    );

    return Card(
      elevation: 4,
      margin: const EdgeInsets.symmetric(vertical: 6),
      color: Theme.of(context).colorScheme.surface,
      child: ListTile(
        onTap: () => _onTap(context, msg, amount, txid, bitcoinDisplay),
        leading: CircleAvatar(
          backgroundColor: Theme.of(
            context,
          ).colorScheme.primary.withOpacity(0.1),
          child: const Icon(Icons.link, color: Colors.yellowAccent),
        ),
        title: Text(
          context.l10n.pendingReceive,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        subtitle: Text(msg, style: Theme.of(context).textTheme.bodyMedium),
        trailing: Text(formatted, style: amountStyle),
      ),
    );
  }
}
