import 'package:ecashapp/db.dart';
import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/providers/preferences_provider.dart';
import 'package:ecashapp/theme.dart';
import '../constants/transaction_keys.dart';
import 'package:ecashapp/widgets/transaction_details.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/utils.dart';
import 'package:provider/provider.dart';

class TransactionItem extends StatelessWidget {
  final Transaction tx;
  final FederationSelector fed;

  const TransactionItem({super.key, required this.tx, required this.fed});

  void _onTap(
    BuildContext context,
    String formattedDate,
    IconData iconData,
  ) async {
    final prefs = context.read<PreferencesProvider>();
    final bitcoinDisplay = prefs.bitcoinDisplay;
    // Transaction details honor the app-level "show msats" setting for all
    // amounts, rather than hardcoding the precision per row.
    final showMsats = prefs.showMsats;
    String fmt(BigInt? msats) =>
        formatBalance(msats, showMsats, bitcoinDisplay);
    final formattedAmount = fmt(tx.amount);
    final icon = Icon(iconData, color: Theme.of(context).colorScheme.primary);
    switch (tx.kind) {
      case TransactionKind_LightningReceive(
        federationFees: final federationFees,
        gatewayFees: final gatewayFees,
        invoiceAmount: final invoiceAmount,
        gateway: final gateway,
        payeePubkey: final payeePubkey,
        paymentHash: final paymentHash,
      ):
        showAppModalBottomSheet(
          context: context,
          childBuilder: () async {
            return TransactionDetails(
              tx: tx,
              details: {
                // Show the invoice's face value (what the payer paid), matching
                // the request screen; the list headline keeps the received amount.
                TransactionDetailKeys.amount: fmt(invoiceAmount),
                if (federationFees > BigInt.zero)
                  TransactionDetailKeys.federationFee: fmt(federationFees),
                if (gatewayFees > BigInt.zero)
                  TransactionDetailKeys.gatewayFee: fmt(gatewayFees),
                TransactionDetailKeys.receivedAmount: fmt(
                  invoiceAmount - federationFees - gatewayFees,
                ),
                TransactionDetailKeys.gateway: gateway,
                TransactionDetailKeys.payeePublicKey: payeePubkey,
                TransactionDetailKeys.paymentHash: paymentHash,
                TransactionDetailKeys.timestamp: formattedDate,
              },
              icon: icon,
              fed: fed,
            );
          },
        );
        break;
      case TransactionKind_LightningSend(
        federationFees: final federationFees,
        gatewayFees: final gatewayFees,
        gateway: final gateway,
        paymentHash: final paymentHash,
        preimage: final preimage,
        lnAddress: final lnAddress,
      ):
        showAppModalBottomSheet(
          context: context,
          childBuilder: () async {
            return TransactionDetails(
              tx: tx,
              details: {
                if (lnAddress != null)
                  TransactionDetailKeys.lnAddress: lnAddress,
                TransactionDetailKeys.amount: formattedAmount,
                if (federationFees > BigInt.zero)
                  TransactionDetailKeys.federationFee: fmt(federationFees),
                if (gatewayFees > BigInt.zero)
                  TransactionDetailKeys.gatewayFee: fmt(gatewayFees),
                TransactionDetailKeys.gateway: gateway,
                TransactionDetailKeys.paymentHash: paymentHash,
                TransactionDetailKeys.preimage: preimage,
                TransactionDetailKeys.timestamp: formattedDate,
              },
              icon: icon,
              fed: fed,
            );
          },
        );
        break;
      case TransactionKind_EcashSend(
        oobNotes: final oobNotes,
        fees: final fees,
      ):
        showAppModalBottomSheet(
          context: context,
          childBuilder: () async {
            return TransactionDetails(
              tx: tx,
              details: {
                TransactionDetailKeys.amount: formattedAmount,
                // The ecash send fee is a federation reissue fee (no gateway).
                // Shown only when non-zero, matching the lightning send detail;
                // exact-change sends are free. Total is what left the wallet.
                if (fees > BigInt.zero)
                  TransactionDetailKeys.federationFee: fmt(fees),
                if (fees > BigInt.zero)
                  TransactionDetailKeys.total: fmt(tx.amount + fees),
                TransactionDetailKeys.ecash: oobNotes,
                TransactionDetailKeys.timestamp: formattedDate,
              },
              icon: icon,
              fed: fed,
            );
          },
        );
        break;
      case TransactionKind_EcashReceive(
        oobNotes: final oobNotes,
        inputFees: final inputFees,
        outputFees: final outputFees,
        dust: final dust,
      ):
        final totalFees =
            (inputFees ?? BigInt.zero) +
            (outputFees ?? BigInt.zero) +
            (dust ?? BigInt.zero);
        final receivedAmount = fmt(tx.amount - totalFees);
        final totalAmount = fmt(tx.amount);
        showAppModalBottomSheet(
          context: context,
          childBuilder: () async {
            return TransactionDetails(
              tx: tx,
              details: {
                TransactionDetailKeys.totalAmount: totalAmount,
                TransactionDetailKeys.receivedAmount: receivedAmount,
                TransactionDetailKeys.inputFees: fmt(inputFees),
                TransactionDetailKeys.outputFees: fmt(outputFees),
                TransactionDetailKeys.dust: fmt(dust),
                TransactionDetailKeys.ecash: oobNotes,
                TransactionDetailKeys.timestamp: formattedDate,
              },
              icon: icon,
              fed: fed,
            );
          },
        );
        break;
      case TransactionKind_LightningRecurring():
        showAppModalBottomSheet(
          context: context,
          childBuilder: () async {
            return TransactionDetails(
              tx: tx,
              details: {
                TransactionDetailKeys.amount: formattedAmount,
                TransactionDetailKeys.timestamp: formattedDate,
              },
              icon: icon,
              fed: fed,
            );
          },
        );
        break;
      case TransactionKind_OnchainReceive(
        address: final address,
        txid: final txid,
        federationFeeMsats: final federationFeeMsats,
      ):
        Map<String, String> details = {
          TransactionDetailKeys.amount: formattedAmount,
          TransactionDetailKeys.timestamp: formattedDate,
          TransactionDetailKeys.address: address,
          TransactionDetailKeys.txid: txid,
        };

        // The federation fee charged on the claimed deposit, computed from the
        // operation's input/output difference. Absent for deposits made before
        // fee tracking existed, so only show it when present.
        if (federationFeeMsats != null && federationFeeMsats > BigInt.zero) {
          details[TransactionDetailKeys.federationFee] = fmt(
            federationFeeMsats,
          );
        }

        showAppModalBottomSheet(
          context: context,
          childBuilder: () async {
            return TransactionDetails(
              tx: tx,
              details: details,
              icon: icon,
              fed: fed,
            );
          },
        );
        break;
      case TransactionKind_OnchainSend(
        address: final address,
        txid: final txid,
        feeRateSatsPerVb: final feeRateSatsPerVb,
        txSizeVb: final txSizeVb,
        feeSats: final feeSats,
        totalSats: final totalSats,
        federationFeeMsats: final federationFeeMsats,
      ):
        Map<String, String> details = {
          TransactionDetailKeys.amount: formattedAmount,
          TransactionDetailKeys.timestamp: formattedDate,
          TransactionDetailKeys.address: address,
          TransactionDetailKeys.txid: txid,
        };

        // we add "Min" to the fee rate and "Max" to the transaction size labels since
        // the federation calculates PegOutFees using max_satisfaction_weight, which
        // overestimates transaction size compared to actual tx sizes you'd see on block
        // explorers. since the fee amount is fixed but calculated for the maximum possible
        // size, this gives us the minimum possible fee rate (fee ÷ max_size = min_rate).
        // the actual fee rate will be slightly higher when the transaction size is smaller.
        // getting the exact tx size and feerate would require either querying a block
        // explorer (privacy leak on withdrawals) or significant technical work, so we
        // show these conservative bounds instead
        if (feeRateSatsPerVb != null) {
          details[TransactionDetailKeys.minFeeRate] =
              '${feeRateSatsPerVb.toStringAsFixed(3)} sats/vB';
        }
        if (txSizeVb != null) {
          details[TransactionDetailKeys.maxTxSize] = '$txSizeVb vB';
        }
        if (feeSats != null) {
          details[TransactionDetailKeys.bitcoinNetworkFee] = fmt(
            feeSats * BigInt.from(1000),
          );
        }
        if (federationFeeMsats != null && federationFeeMsats > BigInt.zero) {
          details[TransactionDetailKeys.federationFee] = fmt(
            federationFeeMsats,
          );
        }
        if (totalSats != null) {
          // All-in cost: on-chain total (amount + miner fee) plus the
          // federation fee deducted from the ecash balance.
          final totalMsats =
              totalSats * BigInt.from(1000) +
              (federationFeeMsats ?? BigInt.zero);
          details[TransactionDetailKeys.total] = fmt(totalMsats);
        }

        showAppModalBottomSheet(
          context: context,
          childBuilder: () async {
            return TransactionDetails(
              tx: tx,
              details: details,
              icon: icon,
              fed: fed,
            );
          },
        );
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bitcoinDisplay = context.select<PreferencesProvider, BitcoinDisplay>(
      (prefs) => prefs.bitcoinDisplay,
    );
    final isIncoming =
        tx.kind is TransactionKind_LightningReceive ||
        tx.kind is TransactionKind_OnchainReceive ||
        tx.kind is TransactionKind_EcashReceive ||
        tx.kind is TransactionKind_LightningRecurring;
    final date = DateTime.fromMillisecondsSinceEpoch(tx.timestamp.toInt());
    final formattedDate = DateFormat.yMMMd().add_jm().format(date);
    final formattedAmount = formatBalance(tx.amount, false, bitcoinDisplay);

    IconData moduleIcon;
    switch (tx.kind) {
      case TransactionKind_LightningRecurring():
      case TransactionKind_LightningReceive():
      case TransactionKind_LightningSend():
        moduleIcon = Icons.flash_on;
        break;
      case TransactionKind_OnchainReceive():
      case TransactionKind_OnchainSend():
        moduleIcon = Icons.link;
        break;
      case TransactionKind_EcashReceive():
      case TransactionKind_EcashSend():
        moduleIcon = Icons.currency_bitcoin;
        break;
    }

    final amountStyle = TextStyle(
      fontWeight: FontWeight.bold,
      color:
          isIncoming ? Theme.of(context).colorScheme.primary : Colors.redAccent,
    );

    return Card(
      elevation: 4,
      margin: const EdgeInsets.symmetric(vertical: 6),
      color: Theme.of(context).colorScheme.surface,
      child: ListTile(
        onTap: () => _onTap(context, formattedDate, moduleIcon),
        leading: CircleAvatar(
          backgroundColor:
              isIncoming
                  ? Theme.of(context).colorScheme.primary.withOpacity(0.1)
                  : Colors.redAccent.withOpacity(0.1),
          child: Icon(
            moduleIcon,
            color:
                isIncoming
                    ? Theme.of(context).colorScheme.primary
                    : Colors.redAccent,
          ),
        ),
        title: Text(
          isIncoming ? context.l10n.txReceived : context.l10n.txSent,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        subtitle: Text(
          formattedDate,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        trailing: Text(formattedAmount, style: amountStyle),
      ),
    );
  }
}
