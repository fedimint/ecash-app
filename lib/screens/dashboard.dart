import 'dart:async';

import 'package:ecashapp/db.dart';
import 'package:ecashapp/recovery_progress.dart';
import 'package:ecashapp/toast.dart';
import 'package:ecashapp/utils.dart';
import 'package:ecashapp/widgets/addresses.dart';
import 'package:ecashapp/widgets/gateways.dart';
import 'package:ecashapp/widgets/note_summary.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_speed_dial/flutter_speed_dial.dart';

import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/number_pad.dart';
import 'package:ecashapp/payment_selector.dart';
import 'package:ecashapp/onchain_receive.dart';
import 'package:ecashapp/scan.dart';
import 'package:ecashapp/theme.dart';
import 'package:ecashapp/models.dart';

import 'package:ecashapp/widgets/dashboard_header.dart';
import 'package:ecashapp/widgets/dashboard_balance.dart';
import 'package:ecashapp/widgets/transactions_list.dart';
import 'package:qr_flutter/qr_flutter.dart';

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
  VoidCallback? _pendingAction;
  VoidCallback? _refreshTransactionsList;
  double? _btcPrice;
  int _addressRefreshKey = 0;
  int _noteRefreshKey = 0;
  LightningAddressConfig? _lnAddressConfig;

  late Stream<MultimintEvent> events;
  late StreamSubscription<MultimintEvent> _subscription;

  @override
  void initState() {
    super.initState();
    recovering = widget.recovering;
    _loadBalance();
    _loadBtcPrice();
    _loadLightningAddress();

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
          _selectedPaymentType = PaymentType.ecash;
          _loadNotes();
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

  Future<void> _loadAddresses() async {
    setState(() {
      _addressRefreshKey++;
    });
  }

  Future<void> _loadNotes() async {
    setState(() {
      _noteRefreshKey++;
    });
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

  Future<void> _loadBtcPrice() async {
    final price = await fetchBtcPrice();
    if (price != null) {
      setState(() {
        _btcPrice = price.toDouble();
      });
    }
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

  void _refreshTransactions() {
    _refreshTransactionsList?.call();
  }

  void _onSendPressed() async {
    if (_selectedPaymentType == PaymentType.lightning) {
      await showAppModalBottomSheet(
        context: context,
        child: PaymentMethodSelector(fed: widget.fed),
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
                btcPrice: _btcPrice,
                onWithdrawCompleted:
                    _selectedPaymentType == PaymentType.onchain
                        ? _refreshTransactions
                        : null,
              ),
        ),
      );
      _loadNotes();
    }
    _loadBalance();
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
                btcPrice: _btcPrice,
                onWithdrawCompleted: null,
              ),
        ),
      );
    } else if (_selectedPaymentType == PaymentType.onchain) {
      await showAppModalBottomSheet(
        context: context,
        child: OnChainReceiveContent(fed: widget.fed),
        heightFactor: 0.33,
      );
      _loadAddresses();
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

  void _showLightningAddressDialog() async {
    final lnAddress =
        '${_lnAddressConfig!.username}@${_lnAddressConfig!.domain}';
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surface,
        title: const Center(
          child: Text(
            "Lightning Address",
            textAlign: TextAlign.center,
          ),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color:
                          Theme.of(context).colorScheme.primary.withOpacity(0.3),
                      blurRadius: 12,
                      spreadRadius: 1,
                    ),
                  ],
                  border: Border.all(
                    color:
                        Theme.of(context).colorScheme.primary.withOpacity(0.7),
                    width: 1.5,
                  ),
                ),
                child: SizedBox(
                  width: 200,
                  height: 200,
                  child: QrImageView(
                    data: lnAddress,
                    version: QrVersions.auto,
                    backgroundColor: Colors.white,
                    padding: EdgeInsets.zero,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.copy, size: 18, color: Colors.black),
                  label: const Text(
                    "Copy Lightning Address",
                    style: TextStyle(color: Colors.black),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    elevation: 4,
                  ),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: lnAddress));
                    ToastService().show(message: "Copied Lightning Address!", duration: const Duration(seconds: 5), onTap: () {}, icon: Icon(Icons.check));
                  },
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.primary,
            ),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text("Close"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.fed.federationName;

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
                    label: 'Receive',
                    backgroundColor: Colors.green,
                    onTap: () => _scheduleAction(_onReceivePressed),
                  ),
                  if (balanceMsats != null && balanceMsats! > BigInt.zero) ...[
                    SpeedDialChild(
                      child: const Icon(Icons.upload),
                      label: 'Send',
                      backgroundColor: Colors.blue,
                      onTap: () => _scheduleAction(_onSendPressed),
                    ),
                  ],
                ],
              ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            DashboardHeader(name: name, network: widget.fed.network),
            if (_lnAddressConfig != null) ...[
              const SizedBox(height: 8),
              if (_lnAddressConfig != null) ...[
                const SizedBox(height: 8),
                GestureDetector(
                  onTap: _showLightningAddressDialog,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.7),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Theme.of(
                          context,
                        ).colorScheme.secondary.withOpacity(0.6),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.flash_on,
                          color: Colors.amber,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${_lnAddressConfig!.username}@${_lnAddressConfig!.domain}',
                          style: Theme.of(
                            context,
                          ).textTheme.bodyMedium?.copyWith(
                            color: Theme.of(context).colorScheme.secondary,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
            const SizedBox(height: 48),
            DashboardBalance(
              balanceMsats: balanceMsats,
              isLoading: isLoadingBalance,
              recovering: recovering,
              showMsats: showMsats,
              onToggle: () => setState(() => showMsats = !showMsats),
              btcPrice: _btcPrice,
            ),
            const SizedBox(height: 48),
            if (recovering) ...[
              RecoveryStatus(
                key: ValueKey(_selectedPaymentType),
                paymentType: _selectedPaymentType,
                fed: widget.fed,
                initialProgress: _recoveryProgress,
              ),
            ] else ...[
              Expanded(
                child: DefaultTabController(
                  length: 2,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TabBar(
                        indicatorColor: Theme.of(context).colorScheme.primary,
                        labelColor: Theme.of(context).colorScheme.primary,
                        unselectedLabelColor: Colors.grey,
                        tabs: [
                          const Tab(text: 'Recent Transactions'),
                          if (_selectedPaymentType == PaymentType.onchain)
                            const Tab(text: 'Addresses'),
                          if (_selectedPaymentType == PaymentType.ecash)
                            const Tab(text: 'Notes'),
                          if (_selectedPaymentType == PaymentType.lightning)
                            const Tab(text: "Gateways"),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Expanded(
                        child: TabBarView(
                          children: [
                            TransactionsList(
                              key: ValueKey(balanceMsats),
                              fed: widget.fed,
                              selectedPaymentType: _selectedPaymentType,
                              recovering: recovering,
                              onClaimed: _loadBalance,
                              onWithdrawCompleted: _refreshTransactions,
                              onRefreshRequested: (refreshCallback) {
                                _refreshTransactionsList = refreshCallback;
                              },
                            ),
                            if (_selectedPaymentType == PaymentType.onchain)
                              OnchainAddressesList(
                                key: ValueKey(_addressRefreshKey),
                                fed: widget.fed,
                                updateAddresses: () {
                                  _loadBalance();
                                  _loadAddresses();
                                },
                              ),
                            if (_selectedPaymentType == PaymentType.ecash)
                              NoteSummary(
                                key: ValueKey(_noteRefreshKey),
                                fed: widget.fed,
                              ),
                            if (_selectedPaymentType == PaymentType.lightning)
                              GatewaysList(fed: widget.fed),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedPaymentType.index,
        onTap: (index) async {
          await _loadProgress(PaymentType.values[index]);
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
