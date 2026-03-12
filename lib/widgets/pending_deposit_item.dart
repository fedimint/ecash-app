import 'package:flutter/material.dart';
import 'package:ecashapp/db.dart';
import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/providers/preferences_provider.dart';
import 'package:ecashapp/utils.dart';
import 'package:provider/provider.dart';

class PendingDepositItem extends StatelessWidget {
  final DepositEventKind event;

  const PendingDepositItem({super.key, required this.event});

  @override
  Widget build(BuildContext context) {
    final bitcoinDisplay = context.select<PreferencesProvider, BitcoinDisplay>(
      (prefs) => prefs.bitcoinDisplay,
    );
    String msg;
    BigInt amount;

    switch (event) {
      case DepositEventKind_Mempool(field0: final e):
        msg = context.l10n.txInMempool;
        amount = e.amount;
        break;
      case DepositEventKind_AwaitingConfs(field0: final e):
        msg = context.l10n.txInBlockRemainingConfs(
          e.blockHeight.toString(),
          e.needed.toString(),
        );
        amount = e.amount;
        break;
      case DepositEventKind_Confirmed(field0: final e):
        msg = context.l10n.txConfirmedClaimingEcash;
        amount = e.amount;
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
