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

import 'package:carbine/widgets/dashboard_header.dart';
import 'package:carbine/widgets/dashboard_balance.dart';
import 'package:carbine/widgets/recent_transactions_header.dart';
import 'package:carbine/widgets/pending_deposit_item.dart';
import 'package:carbine/widgets/transaction_item.dart';

class Dashboard extends StatefulWidget {
  final FederationSelector fed;
  final bool recovering;

  const Dashboard({super.key, required this.fed, required this.recovering});

  @override
  _DashboardState createState() => _DashboardState();
}

enum PaymentType { lightning, onchain, ecash }

class _DashboardState extends State<Dashboard> {
  BigInt? balanceMsats;
  bool isLoadingBalance = true;
  bool isLoadingTransactions = true;
  final List<Transaction> _transactions = [];
  bool showMsats = false;

  Transaction? _lastTransaction;
  bool _hasMore = true;
  bool _isFetchingMore = false;
  final ScrollController _scrollController = ScrollController();

  PaymentType _selectedPaymentType = PaymentType.lightning;

  VoidCallback? _pendingAction;

  late bool recovering;
  late Stream<DepositEvent> depositEvents;
  late StreamSubscription<DepositEvent> _claimSubscription;
  late StreamSubscription<DepositEvent> _depositSubscription;
  final Map<String, DepositEvent> _depositMap = {};

  @override
  void initState() {
    super.initState();
    recovering = widget.recovering;
    _scrollController.addListener(_onScroll);
    _loadBalance();
    _loadTransactions();

    depositEvents =
        subscribeDeposits(
          federationId: widget.fed.federationId,
        ).asBroadcastStream();

    _claimSubscription = depositEvents.listen((e) {
      if (e.eventKind is DepositEventKind_Claimed) {
        if (!mounted) return;
        _loadBalance();
        // this timeout is necessary to ensure the claimed on-chain deposit
        // is in the operation log
        Timer(const Duration(milliseconds: 100), () {
          if (!mounted) return;
          _loadTransactions();
        });
      }
    });

    _depositSubscription = depositEvents.listen((e) {
      String txid;
      switch (e.eventKind) {
        case DepositEventKind_Mempool(field0: final mempoolEvt):
          txid = mempoolEvt.txid;
          break;
        case DepositEventKind_AwaitingConfs(field0: final awaitEvt):
          txid = awaitEvt.txid;
          break;
        case DepositEventKind_Confirmed(field0: final confirmedEvt):
          txid = confirmedEvt.txid;
          break;
        case DepositEventKind_Claimed(field0: final claimedEvt):
          txid = claimedEvt.txid;
          break;
      }
      setState(() => _depositMap[txid] = e);
    });

    if (recovering) _loadFederation();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _depositSubscription.cancel();
    _claimSubscription.cancel();
    super.dispose();
  }

  void _scheduleAction(VoidCallback action) {
    setState(() => _pendingAction = action);
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 100 &&
        !_isFetchingMore &&
        _hasMore) {
      _loadTransactions(loadMore: true);
    }
  }

  List<String> _getKindsForSelectedPaymentType() {
    switch (_selectedPaymentType) {
      case PaymentType.lightning:
        return ['ln', 'lnv2'];
      case PaymentType.onchain:
        return ['wallet'];
      case PaymentType.ecash:
        return ['mint'];
    }
  }

  String _getNoTransactionsMessage() {
    switch (_selectedPaymentType) {
      case PaymentType.lightning:
        return "No lightning transactions yet";
      case PaymentType.onchain:
        return "No onchain transactions yet";
      case PaymentType.ecash:
        return "No ecash transactions yet";
    }
  }

  Future<void> _loadFederation() async {
    await waitForRecovery(inviteCode: widget.fed.inviteCode);
    setState(() => recovering = false);
    _loadBalance();
    _loadTransactions();
  }

  Future<void> _loadBalance() async {
    if (!mounted || recovering) return;
    final bal = await balance(federationId: widget.fed.federationId);
    setState(() {
      balanceMsats = bal;
      isLoadingBalance = false;
    });
  }

  Future<void> _loadTransactions({bool loadMore = false}) async {
    if (recovering) return;
    if (_isFetchingMore) return;
    setState(() => _isFetchingMore = true);

    if (!loadMore) {
      setState(() {
        isLoadingTransactions = true;
        _transactions.clear();
        _hasMore = true;
        _lastTransaction = null;
      });
    }

    final newTxs = await transactions(
      federationId: widget.fed.federationId,
      timestamp: loadMore ? _lastTransaction?.timestamp : null,
      operationId: loadMore ? _lastTransaction?.operationId : null,
      modules: _getKindsForSelectedPaymentType(),
    );

    if (!mounted) return;
    setState(() {
      _transactions.addAll(newTxs);
      if (newTxs.length < 10) _hasMore = false;
      if (newTxs.isNotEmpty) _lastTransaction = newTxs.last;
      isLoadingTransactions = false;
      _isFetchingMore = false;
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
    _loadTransactions();
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
    _loadTransactions();
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
    _loadTransactions();
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.fed.federationName;
    final pending =
        (_selectedPaymentType == PaymentType.onchain
              ? _depositMap.values.toList()
              : <DepositEvent>[])
          ..sort((a, b) {
            final aM = a.eventKind is DepositEventKind_Mempool;
            final bM = b.eventKind is DepositEventKind_Mempool;
            if (aM && !bM) return -1;
            if (!aM && bM) return 1;
            final na =
                a.eventKind is DepositEventKind_AwaitingConfs
                    ? (a.eventKind as DepositEventKind_AwaitingConfs)
                        .field0
                        .needed
                    : BigInt.zero;
            final nb =
                b.eventKind is DepositEventKind_AwaitingConfs
                    ? (b.eventKind as DepositEventKind_AwaitingConfs)
                        .field0
                        .needed
                    : BigInt.zero;
            return nb.compareTo(na);
          });

    final noTxs =
        !recovering &&
        !isLoadingTransactions &&
        _transactions.isEmpty &&
        pending.isEmpty;

    final children = <Widget>[
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
      ...pending.map((e) => PendingDepositItem(event: e)),
      if (recovering) ...[
        const SizedBox(height: 20),
        Center(
          child: Text(
            "Recovering...",
            style: Theme.of(context).textTheme.headlineSmall,
          ),
        ),
      ] else if (isLoadingTransactions) ...[
        const SizedBox(height: 20),
        const Center(child: CircularProgressIndicator()),
      ] else if (noTxs) ...[
        const SizedBox(height: 20),
        Center(child: Text(_getNoTransactionsMessage())),
      ] else ...[
        ..._transactions.map((t) => TransactionItem(tx: t)),
        if (_hasMore)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12.0),
            child: Center(child: CircularProgressIndicator()),
          ),
      ],
    ];

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
      body: ListView(
        controller: _scrollController,
        padding: const EdgeInsets.all(24),
        children: children,
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedPaymentType.index,
        onTap: (index) {
          setState(() => _selectedPaymentType = PaymentType.values[index]);
          _loadTransactions();
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
