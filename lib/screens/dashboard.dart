import 'dart:async';

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

import 'package:ecashapp/widgets/dashboard_balance.dart';
import 'package:ecashapp/widgets/transaction_item.dart';

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
  double _recoveryProgress = 0.0;
  PaymentType _selectedPaymentType = PaymentType.lightning;
  Map<FiatCurrency, double> _btcPrices = {};
  bool _isLoadingPrices = false;
  bool _pricesFailed = false;
  VoidCallback? _pendingAction;
  LightningAddressConfig? _lnAddressConfig;

  List<Transaction> _recentTransactions = [];
  bool _isLoadingTransactions = true;

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
    super.dispose();
    _subscription.cancel();
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
      _recentTransactions = txs.take(5).toList();
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
              onAddressesUpdated: () => _loadBalance(),
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
                      showMsats: showMsats,
                      onToggle: () => setState(() => showMsats = !showMsats),
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
                : ListView(
                  children: [
                    const SizedBox(height: 48),
                    DashboardBalance(
                      balanceMsats: balanceMsats,
                      isLoading: isLoadingBalance,
                      recovering: recovering,
                      showMsats: showMsats,
                      onToggle: () => setState(() => showMsats = !showMsats),
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
                    ),
                    if (widget.fed.network != null &&
                        widget.fed.network!.toLowerCase() != 'bitcoin')
                      Padding(
                        padding: const EdgeInsets.only(top: 4.0),
                        child: Text(
                          context.l10n.testNetworkMessage,
                          style: Theme.of(
                            context,
                          ).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.secondary,
                            fontStyle: FontStyle.italic,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    const SizedBox(height: 48),
                    Text(
                      context.l10n.recentActivity,
                      style: Theme.of(
                        context,
                      ).textTheme.titleSmall?.copyWith(color: Colors.grey),
                    ),
                    const SizedBox(height: 8),
                    if (_isLoadingTransactions)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 32),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else if (_recentTransactions.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 32),
                        child: Center(
                          child: Text(
                            context.l10n.noRecentTransactions,
                            style: const TextStyle(color: Colors.grey),
                          ),
                        ),
                      )
                    else ...[
                      ..._recentTransactions.map(
                        (tx) => TransactionItem(tx: tx, fed: widget.fed),
                      ),
                      const SizedBox(height: 8),
                      Center(
                        child: TextButton(
                          onPressed: _openAllTransactions,
                          child: Text(
                            context.l10n.viewAllTransactions,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                  ],
                ),
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedPaymentType.index,
        onTap: (index) async {
          await _loadProgress(PaymentType.values[index]);
          setState(() {
            _selectedPaymentType = PaymentType.values[index];
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
