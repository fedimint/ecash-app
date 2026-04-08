import 'dart:async';
import 'dart:ui';

import 'package:ecashapp/db.dart';
import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/recovery_progress.dart';
import 'package:ecashapp/utils.dart';
import 'package:ecashapp/widgets/ln_address_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_speed_dial/flutter_speed_dial.dart';

import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/number_pad.dart';
import 'package:ecashapp/screens/lightning_send/recipient_entry.dart';
import 'package:ecashapp/screens/transactions_screen.dart';
import 'package:ecashapp/onchain_receive.dart';
import 'package:ecashapp/scan.dart';
import 'package:ecashapp/theme.dart';
import 'package:ecashapp/models.dart';

import 'package:ecashapp/screens/my_wallet_screen.dart';
import 'package:ecashapp/widgets/dashboard_balance.dart';
import 'package:ecashapp/widgets/empty_transactions.dart';
import 'package:ecashapp/widgets/pending_deposit_item.dart';
import 'package:ecashapp/widgets/transaction_item.dart';

class Dashboard extends StatefulWidget {
  final FederationSelector fed;
  final bool recovering;
  final VoidCallback onLeaveFederation;

  const Dashboard({
    super.key,
    required this.fed,
    required this.recovering,
    required this.onLeaveFederation,
  });

  @override
  _DashboardState createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> {
  BigInt? balanceMsats;
  bool isLoadingBalance = true;
  late bool recovering;
  double _recoveryProgress = 0.0;
  PaymentType _selectedPaymentType = PaymentType.lightning;
  Map<FiatCurrency, double> _btcPrices = {};
  bool _isLoadingPrices = false;
  bool _pricesFailed = false;
  VoidCallback? _pendingAction;
  LightningAddressConfig? _lnAddressConfig;

  List<Transaction> _recentTransactions = [];
  bool _isLoadingTransactions = true;

  final ScrollController _scrollController = ScrollController();
  static const double _headerMaxExtent = 210.0;
  static const double _headerMinExtent = 64.0;

  final Map<String, DepositEventKind> _depositMap = {};
  late final StreamSubscription<DepositEventKind> _depositSubscription;

  late Stream<MultimintEvent> events;
  late StreamSubscription<MultimintEvent> _subscription;

  @override
  void initState() {
    super.initState();
    recovering = widget.recovering;
    _loadBalance();
    _loadBtcPrices();
    _loadLightningAddress();
    _loadRecentTransactions();

    final depositEvents =
        subscribeDeposits(
          federationId: widget.fed.federationId,
        ).asBroadcastStream();

    _depositSubscription = depositEvents.listen((e) {
      String txOutpoint;
      switch (e) {
        case DepositEventKind_Mempool(field0: final evt):
          txOutpoint = evt.outpoint;
        case DepositEventKind_AwaitingConfs(field0: final evt):
          txOutpoint = evt.outpoint;
        case DepositEventKind_Confirmed(field0: final evt):
          txOutpoint = evt.outpoint;
        case DepositEventKind_Claimed(field0: final evt):
          txOutpoint = evt.outpoint;
      }
      if (!mounted) return;
      if (e is DepositEventKind_Claimed) {
        setState(() => _depositMap.remove(txOutpoint));
        // Delay to ensure the claimed deposit is in the operation log
        Timer(const Duration(milliseconds: 100), () {
          if (mounted) {
            _loadBalance();
            _loadRecentTransactions();
          }
        });
      } else {
        setState(() => _depositMap[txOutpoint] = e);
      }
    });

    events = subscribeMultimintEvents().asBroadcastStream();
    _subscription = events.listen((event) async {
      if (event is MultimintEvent_Lightning) {
        final ln = event.field0.$2;
        if (ln is LightningEventKind_InvoicePaid) {
          final federationIdString = await federationIdToString(
            federationId: event.field0.$1,
          );
          final selectorIdString = await federationIdToString(
            federationId: widget.fed.federationId,
          );
          if (federationIdString == selectorIdString) {
            _loadBalance();
            _loadRecentTransactions();
          }
        } else if (ln is LightningEventKind_PaymentSent) {
          final federationIdString = await federationIdToString(
            federationId: event.field0.$1,
          );
          final selectorIdString = await federationIdToString(
            federationId: widget.fed.federationId,
          );
          if (federationIdString == selectorIdString) {
            _loadBalance();
            _loadRecentTransactions();
          }
        }
      } else if (event is MultimintEvent_RecoveryDone) {
        final recoveredFedId = event.field0;
        final currFederationId = await federationIdToString(
          federationId: widget.fed.federationId,
        );
        if (currFederationId == recoveredFedId) {
          if (!mounted) return;
          setState(() => recovering = false);
          _loadBalance();
          _loadLightningAddress();
          _loadRecentTransactions();
        }
      } else if (event is MultimintEvent_Ecash) {
        final federationIdString = await federationIdToString(
          federationId: event.field0.$1,
        );
        final selectorIdString = await federationIdToString(
          federationId: widget.fed.federationId,
        );
        if (federationIdString == selectorIdString) {
          _loadBalance();
          _loadRecentTransactions();
        }
      }
    });
  }

  @override
  void dispose() {
    _depositSubscription.cancel();
    _subscription.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification is! ScrollEndNotification) return false;
    if (!_scrollController.hasClients) return false;
    const collapseRange = _headerMaxExtent - _headerMinExtent;
    final offset = _scrollController.offset;
    if (offset <= 0 || offset >= collapseRange) return false;
    final target = offset < collapseRange / 2 ? 0.0 : collapseRange;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
      );
    });
    return false;
  }

  void _scheduleAction(VoidCallback action) {
    setState(() => _pendingAction = action);
  }

  Future<void> _loadBalance() async {
    if (recovering) return;
    final bal = await balance(federationId: widget.fed.federationId);
    if (!mounted) return;
    setState(() {
      balanceMsats = bal;
      isLoadingBalance = false;
    });
  }

  Future<void> _loadBtcPrices() async {
    setState(() {
      _isLoadingPrices = true;
      _pricesFailed = false;
    });

    final prices = await fetchAllBtcPrices();

    if (!mounted) return;
    setState(() {
      _btcPrices = prices;
      _isLoadingPrices = false;
      _pricesFailed = prices.isEmpty;
    });
  }

  Future<void> _loadLightningAddress() async {
    final config = await getLnAddressConfig(
      federationId: widget.fed.federationId,
    );
    if (!mounted) return;
    setState(() {
      _lnAddressConfig = config;
    });
  }

  List<String> _getModulesForPaymentType() {
    switch (_selectedPaymentType) {
      case PaymentType.lightning:
        return ['ln', 'lnv2'];
      case PaymentType.onchain:
        return ['wallet'];
      case PaymentType.ecash:
        return ['mint'];
    }
  }

  Future<void> _loadRecentTransactions() async {
    if (recovering) return;
    final txs = await transactions(
      federationId: widget.fed.federationId,
      modules: _getModulesForPaymentType(),
    );
    if (!mounted) return;
    setState(() {
      _recentTransactions = txs.take(20).toList();
      _isLoadingTransactions = false;
    });
  }

  void _onSendPressed() async {
    if (_selectedPaymentType == PaymentType.lightning) {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder:
              (_) => RecipientEntry(fed: widget.fed, btcPrices: _btcPrices),
        ),
      );
    } else if (_selectedPaymentType == PaymentType.ecash ||
        _selectedPaymentType == PaymentType.onchain) {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder:
              (_) => NumberPad(
                fed: widget.fed,
                paymentType: _selectedPaymentType,
                btcPrices: _btcPrices,
                onWithdrawCompleted: null,
              ),
        ),
      );
    }
    _loadBalance();
    _loadRecentTransactions();
  }

  void _onReceivePressed() async {
    if (_selectedPaymentType == PaymentType.lightning) {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder:
              (_) => NumberPad(
                fed: widget.fed,
                paymentType: _selectedPaymentType,
                btcPrices: _btcPrices,
                onWithdrawCompleted: null,
              ),
        ),
      );
    } else if (_selectedPaymentType == PaymentType.onchain) {
      await showAppModalBottomSheet(
        context: context,
        childBuilder: () async {
          return OnChainReceiveContent(fed: widget.fed);
        },
        heightFactor: 0.8,
      );
    } else if (_selectedPaymentType == PaymentType.ecash) {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder:
              (_) => ScanQRPage(
                selectedFed: widget.fed,
                paymentType: _selectedPaymentType,
                onPay: (_, _) {},
              ),
        ),
      );
    }
    _loadBalance();
    _loadRecentTransactions();
  }

  void _openMyWallet() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder:
            (_) => MyWalletScreen(
              fed: widget.fed,
              onAddressesUpdated: _loadBalance,
              onLeaveFederation: widget.onLeaveFederation,
            ),
      ),
    );
  }

  void _openAllTransactions() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder:
            (_) => TransactionsScreen(
              fed: widget.fed,
              paymentType: _selectedPaymentType,
              onClaimed: () {
                _loadBalance();
                _loadRecentTransactions();
              },
              onWithdrawCompleted: () => _loadRecentTransactions(),
            ),
      ),
    ).then((_) {
      _loadRecentTransactions();
    });
  }

  Future<void> _loadProgress(PaymentType paymentType) async {
    if (recovering) {
      final progress = await getModuleRecoveryProgress(
        federationId: widget.fed.federationId,
        moduleId: getModuleIdForPaymentType(paymentType),
      );

      if (progress.$2 > 0) {
        double rawProgress = progress.$1.toDouble() / progress.$2.toDouble();
        setState(() => _recoveryProgress = rawProgress.clamp(0.0, 1.0));
      }

      AppLogger.instance.info(
        "$_selectedPaymentType progress: $_recoveryProgress complete: ${progress.$1} total: ${progress.$2}",
      );
    }
  }

  List<DepositEventKind> get _pendingDeposits {
    if (_selectedPaymentType != PaymentType.onchain) return [];
    final pending = _depositMap.values.toList();
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
    return pending;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton:
          recovering
              ? null
              : SpeedDial(
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
                    label: context.l10n.receive,
                    backgroundColor: Colors.green,
                    onTap: () => _scheduleAction(_onReceivePressed),
                  ),
                  if (balanceMsats != null && balanceMsats! > BigInt.zero) ...[
                    SpeedDialChild(
                      child: const Icon(Icons.upload),
                      label: context.l10n.send,
                      backgroundColor: Colors.blue,
                      onTap: () => _scheduleAction(_onSendPressed),
                    ),
                  ],
                ],
              ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child:
            recovering
                ? Column(
                  children: [
                    const Spacer(),
                    DashboardBalance(
                      balanceMsats: balanceMsats,
                      isLoading: isLoadingBalance,
                      recovering: recovering,
                      btcPrices: _btcPrices,
                      isLoadingPrices: _isLoadingPrices,
                      pricesFailed: _pricesFailed,
                    ),
                    const SizedBox(height: 24),
                    RecoveryStatus(
                      key: ValueKey(_selectedPaymentType),
                      paymentType: _selectedPaymentType,
                      fed: widget.fed,
                      initialProgress: _recoveryProgress,
                    ),
                    const Spacer(),
                  ],
                )
                : NotificationListener<ScrollNotification>(
                  onNotification: _handleScrollNotification,
                  child: CustomScrollView(
                    controller: _scrollController,
                    slivers: [
                      SliverPersistentHeader(
                        pinned: true,
                        delegate: _DashboardBalanceHeader(
                          minExtent: _headerMinExtent,
                          maxExtent: _headerMaxExtent,
                          balanceMsats: balanceMsats,
                          isLoading: isLoadingBalance,
                          recovering: recovering,
                          btcPrices: _btcPrices,
                          isLoadingPrices: _isLoadingPrices,
                          pricesFailed: _pricesFailed,
                          lnAddressConfig: _lnAddressConfig,
                          onLnAddressTap:
                              _lnAddressConfig != null
                                  ? () => showLightningAddressDialog(
                                    context,
                                    _lnAddressConfig!.username,
                                    _lnAddressConfig!.domain,
                                    _lnAddressConfig!.lnurl,
                                  )
                                  : null,
                          onWalletTap: _openMyWallet,
                          backgroundColor:
                              Theme.of(context).scaffoldBackgroundColor,
                        ),
                      ),
                      if (widget.fed.network != null &&
                          widget.fed.network!.toLowerCase() != 'bitcoin')
                        SliverToBoxAdapter(
                          child: AnimatedBuilder(
                            animation: _scrollController,
                            builder: (context, child) {
                              const range = _headerMaxExtent - _headerMinExtent;
                              final offset =
                                  _scrollController.hasClients
                                      ? _scrollController.offset
                                      : 0.0;
                              final t = (offset / range).clamp(0.0, 1.0);
                              final opacity = (1.0 - t * 2.0).clamp(0.0, 1.0);
                              return ClipRect(
                                child: Align(
                                  alignment: Alignment.topCenter,
                                  heightFactor: 1.0 - t,
                                  child: Opacity(
                                    opacity: opacity,
                                    child: child,
                                  ),
                                ),
                              );
                            },
                            child: Padding(
                              padding: const EdgeInsets.only(top: 4.0),
                              child: Text(
                                context.l10n.testNetworkMessage,
                                style: Theme.of(
                                  context,
                                ).textTheme.bodySmall?.copyWith(
                                  color:
                                      Theme.of(context).colorScheme.secondary,
                                  fontStyle: FontStyle.italic,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ),
                        ),
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 8.0),
                          child: Row(
                            children: [
                              Text(
                                context.l10n.recentActivity,
                                style: Theme.of(context).textTheme.titleSmall
                                    ?.copyWith(color: Colors.grey),
                              ),
                              const Spacer(),
                              TextButton(
                                onPressed: _openAllTransactions,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      context.l10n.viewAll,
                                      style: TextStyle(
                                        color:
                                            Theme.of(
                                              context,
                                            ).colorScheme.primary,
                                        fontSize: 13,
                                      ),
                                    ),
                                    const SizedBox(width: 2),
                                    Icon(
                                      Icons.chevron_right,
                                      size: 18,
                                      color:
                                          Theme.of(context).colorScheme.primary,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SliverToBoxAdapter(child: SizedBox(height: 8)),
                      if (_isLoadingTransactions && _pendingDeposits.isEmpty)
                        const SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.symmetric(vertical: 32),
                            child: Center(child: CircularProgressIndicator()),
                          ),
                        )
                      else if (_recentTransactions.isEmpty &&
                          _pendingDeposits.isEmpty)
                        SliverToBoxAdapter(
                          child: EmptyTransactionsState(
                            paymentType: _selectedPaymentType,
                            onReceivePressed: _onReceivePressed,
                          ),
                        )
                      else
                        SliverList(
                          delegate: SliverChildBuilderDelegate(
                            (context, index) {
                              if (index < _pendingDeposits.length) {
                                return PendingDepositItem(
                                  event: _pendingDeposits[index],
                                );
                              }
                              final tx =
                                  _recentTransactions[index -
                                      _pendingDeposits.length];
                              return TransactionItem(tx: tx, fed: widget.fed);
                            },
                            childCount:
                                _pendingDeposits.length +
                                _recentTransactions.length,
                          ),
                        ),
                      const SliverToBoxAdapter(child: SizedBox(height: 8)),
                    ],
                  ),
                ),
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedPaymentType.index,
        onTap: (index) async {
          await _loadProgress(PaymentType.values[index]);
          setState(() {
            _selectedPaymentType = PaymentType.values[index];
            _recentTransactions = [];
            _isLoadingTransactions = true;
          });
          _loadRecentTransactions();
        },
        selectedItemColor: Theme.of(context).colorScheme.primary,
        unselectedItemColor: Colors.grey,
        items: [
          BottomNavigationBarItem(
            icon: const Icon(Icons.flash_on),
            label: context.l10n.lightning,
          ),
          BottomNavigationBarItem(
            icon: const Icon(Icons.link),
            label: context.l10n.onchain,
          ),
          BottomNavigationBarItem(
            icon: const Icon(Icons.currency_bitcoin),
            label: context.l10n.ecash,
          ),
        ],
      ),
    );
  }
}

class _DashboardBalanceHeader extends SliverPersistentHeaderDelegate {
  @override
  final double minExtent;
  @override
  final double maxExtent;
  final BigInt? balanceMsats;
  final bool isLoading;
  final bool recovering;
  final Map<FiatCurrency, double> btcPrices;
  final bool isLoadingPrices;
  final bool pricesFailed;
  final LightningAddressConfig? lnAddressConfig;
  final VoidCallback? onLnAddressTap;
  final VoidCallback? onWalletTap;
  final Color backgroundColor;

  _DashboardBalanceHeader({
    required this.minExtent,
    required this.maxExtent,
    required this.balanceMsats,
    required this.isLoading,
    required this.recovering,
    required this.btcPrices,
    required this.isLoadingPrices,
    required this.pricesFailed,
    required this.lnAddressConfig,
    required this.onLnAddressTap,
    required this.onWalletTap,
    required this.backgroundColor,
  });

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final range = maxExtent - minExtent;
    final t = (shrinkOffset / range).clamp(0.0, 1.0);
    return ClipRect(
      child: SizedBox.expand(
        child: ColoredBox(
          color: backgroundColor,
          child: Padding(
            padding: EdgeInsets.only(top: lerpDouble(48.0, 8.0, t)!),
            child: DashboardBalance(
              balanceMsats: balanceMsats,
              isLoading: isLoading,
              recovering: recovering,
              btcPrices: btcPrices,
              isLoadingPrices: isLoadingPrices,
              pricesFailed: pricesFailed,
              lnAddressConfig: lnAddressConfig,
              onLnAddressTap: onLnAddressTap,
              onWalletTap: onWalletTap,
              collapseProgress: t,
            ),
          ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _DashboardBalanceHeader oldDelegate) {
    return balanceMsats != oldDelegate.balanceMsats ||
        isLoading != oldDelegate.isLoading ||
        recovering != oldDelegate.recovering ||
        btcPrices != oldDelegate.btcPrices ||
        isLoadingPrices != oldDelegate.isLoadingPrices ||
        pricesFailed != oldDelegate.pricesFailed ||
        lnAddressConfig != oldDelegate.lnAddressConfig ||
        minExtent != oldDelegate.minExtent ||
        maxExtent != oldDelegate.maxExtent;
  }
}
