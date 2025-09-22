import 'dart:async';
import 'package:flutter/material.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/models.dart';
import 'package:ecashapp/widgets/pending_deposit_item.dart';
import 'package:ecashapp/widgets/transaction_item.dart';

class TransactionsList extends StatefulWidget {
  final FederationSelector fed;
  final PaymentType selectedPaymentType;
  final bool recovering;
  final VoidCallback onClaimed;
  final VoidCallback? onWithdrawCompleted;
  final void Function(VoidCallback)? onRefreshRequested;

  const TransactionsList({
    super.key,
    required this.fed,
    required this.selectedPaymentType,
    required this.recovering,
    required this.onClaimed,
    this.onWithdrawCompleted,
    this.onRefreshRequested,
  });

  @override
  _TransactionsListState createState() => _TransactionsListState();
}

typedef TxOutpoint = String;

class _TransactionsListState extends State<TransactionsList> {
  final List<Transaction> _transactions = [];
  final Map<TxOutpoint, DepositEventKind> _depositMap = {};
  bool _isLoading = true;
  bool _hasMore = true;
  Transaction? _lastTransaction;
  bool _isFetchingMore = false;
  late final StreamSubscription<DepositEventKind> _claimSubscription;
  late final StreamSubscription<DepositEventKind> _depositSubscription;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _setupStreamsAndLoad();

    // Register the refresh callback with the parent
    widget.onRefreshRequested?.call(_loadTransactions);
  }

  void _setupStreamsAndLoad() {
    _loadTransactions();

    final depositEvents =
        subscribeDeposits(
          federationId: widget.fed.federationId,
        ).asBroadcastStream();

    _claimSubscription = depositEvents.listen((e) {
      if (e is DepositEventKind_Claimed) {
        widget.onClaimed();
        // this timeout is necessary to ensure the claimed on-chain deposit
        // is in the operation log
        Timer(const Duration(milliseconds: 100), () {
          if (mounted) _loadTransactions();
        });
      }
    });

    _depositSubscription = depositEvents.listen((e) {
      String txOutpoint;
      switch (e) {
        case DepositEventKind_Mempool(field0: final mempoolEvt):
          txOutpoint = mempoolEvt.outpoint;
          break;
        case DepositEventKind_AwaitingConfs(field0: final awaitEvt):
          txOutpoint = awaitEvt.outpoint;
          break;
        case DepositEventKind_Confirmed(field0: final confirmedEvt):
          txOutpoint = confirmedEvt.outpoint;
          break;
        case DepositEventKind_Claimed(field0: final claimedEvt):
          txOutpoint = claimedEvt.outpoint;
          break;
      }
      setState(() => _depositMap[txOutpoint] = e);
    });
  }

  @override
  void didUpdateWidget(covariant TransactionsList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedPaymentType != widget.selectedPaymentType) {
      _transactions.clear();
      // we explicitly skip clearing the depositMap so we can keep track of
      // pending deposits without needing to restart the event stream
      _hasMore = true;
      _lastTransaction = null;
      _isLoading = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(0);
        }
      });
      _loadTransactions();
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _depositSubscription.cancel();
    _claimSubscription.cancel();
    super.dispose();
  }

  List<String> _getKindsForSelectedPaymentType() {
    switch (widget.selectedPaymentType) {
      case PaymentType.lightning:
        return ['ln', 'lnv2'];
      case PaymentType.onchain:
        return ['wallet'];
      case PaymentType.ecash:
        return ['mint'];
    }
  }

  Future<void> _loadTransactions({bool loadMore = false}) async {
    if (_isFetchingMore) return;
    setState(() => _isFetchingMore = true);

    if (!loadMore) {
      setState(() {
        _transactions.clear();
        _hasMore = true;
        _lastTransaction = null;
        _isLoading = true;
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
      _isLoading = false;
      _isFetchingMore = false;
    });
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 100 &&
        !_isFetchingMore &&
        _hasMore) {
      _loadTransactions(loadMore: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending =
        widget.selectedPaymentType == PaymentType.onchain
            ? _depositMap.values.toList()
            : <DepositEventKind>[];

    pending.sort((a, b) {
      final aM = a is DepositEventKind_Mempool;
      final bM = b is DepositEventKind_Mempool;
      if (aM && !bM) return -1;
      if (!aM && bM) return 1;
      final na =
          a is DepositEventKind_AwaitingConfs ? a.field0.needed : BigInt.zero;
      final nb =
          b is DepositEventKind_AwaitingConfs ? b.field0.needed : BigInt.zero;
      return nb.compareTo(na);
    });

    if (_isLoading && pending.isEmpty) {
      return const SizedBox(
        height: 20,
        child: Center(child: CircularProgressIndicator()),
      );
    }

    final noTxs =
        _transactions.isEmpty &&
        pending.isEmpty &&
        !_isLoading &&
        !widget.recovering;

    if (noTxs) {
      String message;
      switch (widget.selectedPaymentType) {
        case PaymentType.lightning:
          message = "No lightning transactions yet";
          break;
        case PaymentType.onchain:
          message = "No onchain transactions yet";
          break;
        case PaymentType.ecash:
          message = "No Ecash transactions yet";
          break;
      }
      return SizedBox(height: 20, child: Center(child: Text(message)));
    }

    return ListView(
      controller: _scrollController,
      shrinkWrap: true,
      physics: ClampingScrollPhysics(),
      children: [
        ...pending.map((e) => PendingDepositItem(event: e)),
        ..._transactions.map((tx) => TransactionItem(tx: tx, fed: widget.fed)),
        if (_hasMore)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12.0),
            child: Center(child: CircularProgressIndicator()),
          ),
      ],
    );
  }
}
