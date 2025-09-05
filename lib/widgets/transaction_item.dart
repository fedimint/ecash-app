import 'package:ecashapp/theme.dart';
import 'package:ecashapp/widgets/transaction_details.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/utils.dart';

class TransactionItem extends StatelessWidget {
  final Transaction tx;
  final FederationSelector fed;

  const TransactionItem({super.key, required this.tx, required this.fed});

  void _onTap(
    BuildContext context,
    String formattedAmount,
    String formattedDate,
    IconData iconData,
  ) async {
    final icon = Icon(iconData, color: Theme.of(context).colorScheme.primary);
    switch (tx.kind) {
      case TransactionKind_LightningReceive(
        fees: final fees,
        gateway: final gateway,
        payeePubkey: final payeePubkey,
        paymentHash: final paymentHash,
      ):
        showAppModalBottomSheet(
          context: context,
          child: TransactionDetails(
            tx: tx,
            details: {
              'Amount': formattedAmount,
              "Fees": formatBalance(fees, true),
              "Gateway": gateway,
              "Payee Public Key": payeePubkey,
              "Payment Hash": paymentHash,
              'Timestamp': formattedDate,
            },
            icon: icon,
            fed: fed,
          ),
        );
        break;
      case TransactionKind_LightningSend(
        fees: final fees,
        gateway: final gateway,
        paymentHash: final paymentHash,
        preimage: final preimage,
      ):
        showAppModalBottomSheet(
          context: context,
          child: TransactionDetails(
            tx: tx,
            details: {
              'Amount': formattedAmount,
              "Fees": formatBalance(fees, true),
              "Gateway": gateway,
              "Payment Hash": paymentHash,
              "Preimage": preimage,
              'Timestamp': formattedDate,
            },
            icon: icon,
            fed: fed,
          ),
        );
        break;
      case TransactionKind_EcashSend(
        oobNotes: final oobNotes,
        fees: final fees,
      ):
        showAppModalBottomSheet(
          context: context,
          child: TransactionDetails(
            tx: tx,
            details: {
              'Amount': formattedAmount,
              "Fees": formatBalance(fees, true),
              "E-Cash": oobNotes,
              'Timestamp': formattedDate,
            },
            icon: icon,
            fed: fed,
          ),
        );
        break;
      case TransactionKind_EcashReceive(
        oobNotes: final oobNotes,
        fees: final fees,
      ):
        showAppModalBottomSheet(
          context: context,
          child: TransactionDetails(
            tx: tx,
            details: {
              'Amount': formattedAmount,
              "Fees": formatBalance(fees, true),
              "E-Cash": oobNotes,
              'Timestamp': formattedDate,
            },
            icon: icon,
            fed: fed,
          ),
        );
        break;
      case TransactionKind_LightningRecurring():
        showAppModalBottomSheet(
          context: context,
          child: TransactionDetails(
            tx: tx,
            details: {'Amount': formattedAmount, 'Timestamp': formattedDate},
            icon: icon,
            fed: fed,
          ),
        );
        break;
      case TransactionKind_OnchainReceive(
        address: final address,
        txid: final txid,
      ):
        Map<String, String> details = {
          'Amount': formattedAmount,
          'Timestamp': formattedDate,
          'Address': address,
          'Txid': txid,
        };

        showAppModalBottomSheet(
          context: context,
          child: TransactionDetails(
            tx: tx,
            details: details,
            icon: icon,
            fed: fed,
          ),
        );
        break;
      case TransactionKind_OnchainSend(
        address: final address,
        txid: final txid,
        feeRateSatsPerVb: final feeRateSatsPerVb,
        txSizeVb: final txSizeVb,
        feeSats: final feeSats,
        totalSats: final totalSats,
      ):
        Map<String, String> details = {
          'Amount': formattedAmount,
          'Timestamp': formattedDate,
          'Address': address,
          'Txid': txid,
        };

        // we add "Max" to the fee rate and transaction size labels since the
        // federation calculates PegOutFees using max_satisfaction_weight, which
        // overestimates compared to actual tx sizes you'd see on block explorers.
        // getting the exact tx size and feerate would require either querying a
        // block explorer (privacy leak on withdrawals) or significant technical
        // work, so we show the conservative estimates instead
        if (feeRateSatsPerVb != null) {
          details['Max Fee Rate'] =
              '${feeRateSatsPerVb.toStringAsFixed(3)} sats/vB';
        }
        if (txSizeVb != null) {
          details['Max Tx Size'] = '$txSizeVb vB';
        }
        if (feeSats != null) {
          details['Fee'] = formatBalance(feeSats * BigInt.from(1000), false);
        }
        if (totalSats != null) {
          details['Total'] = formatBalance(
            totalSats * BigInt.from(1000),
            false,
          );
        }

        showAppModalBottomSheet(
          context: context,
          child: TransactionDetails(
            tx: tx,
            details: details,
            icon: icon,
            fed: fed,
          ),
        );
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isIncoming =
        tx.kind is TransactionKind_LightningReceive ||
        tx.kind is TransactionKind_OnchainReceive ||
        tx.kind is TransactionKind_EcashReceive ||
        tx.kind is TransactionKind_LightningRecurring;
    final date = DateTime.fromMillisecondsSinceEpoch(tx.timestamp.toInt());
    final formattedDate = DateFormat.yMMMd().add_jm().format(date);
    final formattedAmount = formatBalance(tx.amount, false);

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
        onTap:
            () => _onTap(context, formattedAmount, formattedDate, moduleIcon),
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
          isIncoming ? "Received" : "Sent",
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
