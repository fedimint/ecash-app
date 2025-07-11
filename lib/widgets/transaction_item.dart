import 'package:carbine/theme.dart';
import 'package:carbine/widgets/transaction_details.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:carbine/multimint.dart';
import 'package:carbine/utils.dart';

class TransactionItem extends StatelessWidget {
  final Transaction tx;

  const TransactionItem({super.key, required this.tx});

  void _onTap(BuildContext context, String formattedAmount, String formattedDate, IconData iconData) {
    final icon = Icon(iconData, color: Colors.greenAccent);
    switch (tx.kind) {
      case TransactionKind_LightningReceive(fees: final fees, gateway: final gateway, payeePubkey: final payeePubkey, paymentHash: final paymentHash):
        showCarbineModalBottomSheet(
          context: context,
          child: TransactionDetails(
            title: "Lightning Receive",
            details: {
              'Amount': formattedAmount,
              "Fees": formatBalance(fees, true),
              "Gateway": gateway,
              "Payee Public Key": payeePubkey,
              "Payment Hash": paymentHash,
              'Timestamp': formattedDate,
            },
            icon: icon,
          ),
        );
        break;
      case TransactionKind_LightningSend(fees: final fees, gateway: final gateway, paymentHash: final paymentHash, preimage: final preimage):
        showCarbineModalBottomSheet(
          context: context,
          child: TransactionDetails(
            title: "Lightning Send",
            details: {
              'Amount': formattedAmount,
              "Fees": formatBalance(fees, true),
              "Gateway": gateway,
              "Payment Hash": paymentHash,
              "Preimage": preimage,
              'Timestamp': formattedDate,
            },
            icon: icon,
          ),
        );
        break;
      case TransactionKind_EcashSend(oobNotes: final oobNotes, fees: final fees):
        showCarbineModalBottomSheet(
          context: context,
          child: TransactionDetails(
            title: "Ecash Send",
            details: {
              'Amount': formattedAmount,
              "Fees": formatBalance(fees, true),
              "Ecash": getAbbreviatedText(oobNotes),
              'Timestamp': formattedDate,
            },
            icon: icon,
          ),
        );
        break;
      case TransactionKind_EcashReceive(oobNotes: final oobNotes, fees: final fees):
        showCarbineModalBottomSheet(
          context: context,
          child: TransactionDetails(
            title: "Ecash Receive",
            details: {
              'Amount': formattedAmount,
              "Fees": formatBalance(fees, true),
              "Ecash": getAbbreviatedText(oobNotes),
              'Timestamp': formattedDate,
            },
            icon: icon,
          ),
        );
        break;
      // TODO: Fill in with onchain data
      case TransactionKind_OnchainReceive():
      case TransactionKind_OnchainSend():
        showCarbineModalBottomSheet(
          context: context,
          child: TransactionDetails(
            title: "Transaction",
            details: {
              'Amount': formattedAmount,
              'Timestamp': formattedDate,
            },
            icon: icon,
          ),
        );
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isIncoming = tx.kind is TransactionKind_LightningReceive || tx.kind is TransactionKind_OnchainReceive || tx.kind is TransactionKind_EcashReceive;
    final date = DateTime.fromMillisecondsSinceEpoch(tx.timestamp.toInt());
    final formattedDate = DateFormat.yMMMd().add_jm().format(date);
    final formattedAmount = formatBalance(tx.amount, false);

    IconData moduleIcon;
    switch (tx.kind) {
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
      color: isIncoming ? Colors.greenAccent : Colors.redAccent,
    );

    return Card(
      elevation: 4,
      margin: const EdgeInsets.symmetric(vertical: 6),
      color: Theme.of(context).colorScheme.surface,
      child: ListTile(
        onTap: () => _onTap(context, formattedAmount, formattedDate, moduleIcon),
        leading: CircleAvatar(
          backgroundColor:
              isIncoming
                  ? Colors.greenAccent.withOpacity(0.1)
                  : Colors.redAccent.withOpacity(0.1),
          child: Icon(
            moduleIcon,
            color: isIncoming ? Colors.greenAccent : Colors.redAccent,
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
