import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_speed_dial/flutter_speed_dial.dart';

import 'package:carbine/lib.dart';
import 'package:carbine/multimint.dart';
import 'package:carbine/number_pad.dart';
import 'package:carbine/payment_selector.dart';
import 'package:carbine/onchain_receive.dart';
import 'package:carbine/scan.dart';
import 'package:carbine/refund.dart';
import 'package:carbine/theme.dart';
import 'package:carbine/models.dart';

import 'package:carbine/widgets/dashboard_header.dart';
import 'package:carbine/widgets/dashboard_balance.dart';
import 'package:carbine/widgets/recent_transactions_header.dart';
import 'package:carbine/widgets/transactions_list.dart';

class Dashboard extends StatefulWidget {
  final FederationSelector fed;
  final bool recovering;

  const Dashboard({super.key, required this.fed, required this.recovering});

  @override
  _DashboardState createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> {
  BigInt? balanceMsats;
  bool isLoadingBalance = true;
  bool showMsats = false;
  late bool recovering;
  PaymentType _selectedPaymentType = PaymentType.lightning;
  VoidCallback? _pendingAction;

  @override
  void initState() {
    super.initState();
    recovering = widget.recovering;
    _loadBalance();
    if (recovering) _loadFederation();
  }

  void _scheduleAction(VoidCallback action) {
    setState(() => _pendingAction = action);
  }

  Future<void> _loadFederation() async {
    await waitForRecovery(inviteCode: widget.fed.inviteCode);
    setState(() => recovering = false);
    _loadBalance();
  }

  Future<void> _loadBalance() async {
    if (!mounted || recovering) return;
    final bal = await balance(federationId: widget.fed.federationId);
    setState(() {
      balanceMsats = bal;
      isLoadingBalance = false;
    });
  }

  void _onSendPressed() async {
    if (_selectedPaymentType == PaymentType.lightning) {
      await showCarbineModalBottomSheet(
        context: context,
        child: PaymentMethodSelector(fed: widget.fed),
      );
    } else if (_selectedPaymentType == PaymentType.ecash) {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder:
              (_) =>
                  NumberPad(fed: widget.fed, paymentType: _selectedPaymentType),
        ),
      );
    }
    _loadBalance();
  }

  void _onReceivePressed() async {
    if (_selectedPaymentType == PaymentType.lightning) {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder:
              (_) =>
                  NumberPad(fed: widget.fed, paymentType: _selectedPaymentType),
        ),
      );
    } else if (_selectedPaymentType == PaymentType.onchain) {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => OnChainReceive(fed: widget.fed)),
      );
    } else if (_selectedPaymentType == PaymentType.ecash) {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => ScanQRPage(selectedFed: widget.fed)),
      );
    }
    _loadBalance();
  }

  void _onRefundPressed() async {
    await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder:
            (_) => RefundConfirmationPage(
              fed: widget.fed,
              balanceMsats: balanceMsats!,
            ),
      ),
    );
    _loadBalance();
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.fed.federationName;

    return Scaffold(
      floatingActionButton: SpeedDial(
        icon: Icons.add,
        activeIcon: Icons.close,
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Colors.white,
        onClose: () async {
          if (_pendingAction != null) {
            await Future.delayed(const Duration(milliseconds: 200));
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _pendingAction!();
              _pendingAction = null;
            });
          }
        },
        children: [
          SpeedDialChild(
            child: const Icon(Icons.download),
            label: 'Receive',
            backgroundColor: Colors.green,
            onTap: () => _scheduleAction(_onReceivePressed),
          ),
          if (balanceMsats != null && balanceMsats! > BigInt.zero)
            if (_selectedPaymentType == PaymentType.onchain)
              SpeedDialChild(
                child: const Icon(Icons.reply),
                label: 'Refund',
                backgroundColor: Colors.orange,
                onTap: () => _scheduleAction(_onRefundPressed),
              )
            else
              SpeedDialChild(
                child: const Icon(Icons.upload),
                label: 'Send',
                backgroundColor: Colors.blue,
                onTap: () => _scheduleAction(_onSendPressed),
              ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const SizedBox(height: 32),
            DashboardHeader(name: name, network: widget.fed.network),
            const SizedBox(height: 48),
            DashboardBalance(
              balanceMsats: balanceMsats,
              isLoading: isLoadingBalance,
              recovering: recovering,
              showMsats: showMsats,
              onToggle: () => setState(() => showMsats = !showMsats),
            ),
            const SizedBox(height: 48),
            const RecentTransactionsHeader(),
            // Expanded is necessary so only the tx list is scrollable, not the
            // entire dashboard
            Expanded(
              child: TransactionsList(
                fed: widget.fed,
                selectedPaymentType: _selectedPaymentType,
                recovering: recovering,
                onClaimed: _loadBalance,
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedPaymentType.index,
        onTap: (index) {
          setState(() => _selectedPaymentType = PaymentType.values[index]);
        },
        selectedItemColor: Theme.of(context).colorScheme.primary,
        unselectedItemColor: Colors.grey,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.flash_on),
            label: 'Lightning',
          ),
          BottomNavigationBarItem(icon: Icon(Icons.link), label: 'Onchain'),
          BottomNavigationBarItem(
            icon: Icon(Icons.currency_bitcoin),
            label: 'Ecash',
          ),
        ],
      ),
    );
  }
}
