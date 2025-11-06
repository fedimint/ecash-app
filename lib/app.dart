import 'dart:async';

import 'package:ecashapp/discover.dart';
import 'package:ecashapp/screens/dashboard.dart';
import 'package:ecashapp/generated/lib.dart';
import 'package:ecashapp/generated/multimint.dart';
import 'package:ecashapp/providers/preferences_provider.dart';
import 'package:ecashapp/scan.dart';
import 'package:ecashapp/setttings.dart';
import 'package:ecashapp/sidebar.dart';
import 'package:ecashapp/theme.dart';
import 'package:ecashapp/toast.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

final invoicePaidToastVisible = ValueNotifier<bool>(true);

class MyApp extends StatefulWidget {
  final List<(FederationSelector, bool)> initialFederations;
  final bool recoverFederationInviteCodes;
  const MyApp({super.key, required this.initialFederations, required this.recoverFederationInviteCodes});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  late List<(FederationSelector, bool)> _feds;
  int _refreshTrigger = 0;
  FederationSelector? _selectedFederation;
  bool? _isRecovering;

  late Stream<MultimintEvent> events;
  late StreamSubscription<MultimintEvent> _subscription;

  final GlobalKey<NavigatorState> _navigatorKey = ToastService().navigatorKey;

  bool recoverFederations = false;

  String _recoveryStatus = "Retrieving federation backup from Nostr...";
  Timer? _recoveryTimer;
  int _recoverySecondsRemaining = 30;

  @override
  void initState() {
    super.initState();
    _feds = widget.initialFederations;

    if (_feds.isNotEmpty) {
      _selectedFederation = _feds.first.$1;
      _isRecovering = _feds.first.$2;
    } else if (_feds.isEmpty && widget.recoverFederationInviteCodes) {
      _rejoinFederations();
    }

    events = subscribeMultimintEvents().asBroadcastStream();
    _subscription = events.listen((event) async {
      if (event is MultimintEvent_Lightning) {
        final ln = event.field0.$2;
        if (ln is LightningEventKind_InvoicePaid) {
          if (!invoicePaidToastVisible.value) {
            AppLogger.instance.info("Request modal visible — skipping toast.");
            return;
          }

          final amountMsats = ln.field0.amountMsats;
          await _handleFundsReceived(
            federationId: event.field0.$1,
            amountMsats: amountMsats,
            icon: Icon(Icons.flash_on, color: Colors.amber),
          );
        }
      } else if (event is MultimintEvent_Log) {
        AppLogger.instance.rustLog(event.field0, event.field1);
      } else if (event is MultimintEvent_Ecash) {
        if (!invoicePaidToastVisible.value) {
          AppLogger.instance.info("Request modal visible — skipping toast.");
          return;
        }
        final amountMsats = event.field0.$2;
        await _handleFundsReceived(
          federationId: event.field0.$1,
          amountMsats: amountMsats,
          icon: Icon(Icons.currency_bitcoin, color: Theme.of(context).colorScheme.primary),
        );
      } else if (event is MultimintEvent_NostrRecovery) {
        if (event.field2 != null) {
          ToastService().show(
            message: "Joined ${event.field2!.federationName}. Recovering...",
            duration: const Duration(seconds: 5),
            onTap: () {},
            icon: Icon(Icons.info),
          );
        } else {
          if (_selectedFederation == null) {
            _startOrResetRecoveryTimer();
            setState(() {
              _recoveryStatus = "Trying to re-join ${event.field0} using peer ${event.field1}...";
            });
          }
        }
      }
    });
  }

  void _startOrResetRecoveryTimer() {
    _recoveryTimer?.cancel();
    setState(() {
      _recoverySecondsRemaining = 30;
    });

    _recoveryTimer = Timer.periodic(Duration(seconds: 1), (timer) {
      if (_recoverySecondsRemaining <= 1) {
        timer.cancel();
      }
      setState(() {
        _recoverySecondsRemaining--;
      });
    });
  }

  Future<void> _handleFundsReceived({
    required FederationId federationId,
    required BigInt amountMsats,
    required Icon icon,
  }) async {
    final context = _navigatorKey.currentContext;
    if (context == null) return;

    final bitcoinDisplay = context.read<PreferencesProvider>().bitcoinDisplay;
    final amount = formatBalance(amountMsats, false, bitcoinDisplay);
    final federationIdString = await federationIdToString(federationId: federationId);

    FederationSelector? selector;
    bool? recovering;

    for (var sel in _feds) {
      final idString = await federationIdToString(federationId: sel.$1.federationId);
      if (idString == federationIdString) {
        selector = sel.$1;
        recovering = sel.$2;
        break;
      }
    }

    if (selector == null) return;

    final name = selector.federationName;
    AppLogger.instance.info("$name received $amount");

    ToastService().show(
      message: "$name received $amount",
      duration: const Duration(seconds: 7),
      onTap: () {
        _navigatorKey.currentState?.popUntil((route) => route.isFirst);
        _setSelectedFederation(selector!, recovering!);
      },
      icon: icon,
    );
  }

  Future<void> _leaveFederation() async {
    await _refreshFederations();
    if (_feds.isNotEmpty) {
      _selectedFederation = _feds.first.$1;
      _isRecovering = _feds.first.$2;
    } else {
      _selectedFederation = null;
      _isRecovering = null;
    }
  }

  Future<void> _rejoinFederations() async {
    setState(() {
      recoverFederations = true;
    });
    await rejoinFromBackupInvites();
    await _refreshFederations();

    if (_feds.isNotEmpty) {
      final first = _feds.first;
      _setSelectedFederation(first.$1, first.$2);
    }

    setState(() {
      recoverFederations = false;
    });

    ToastService().show(
      message: "Re-joined all federations from Nostr",
      duration: const Duration(seconds: 5),
      onTap: () {},
      icon: Icon(Icons.info),
    );
  }

  @override
  void dispose() {
    _subscription.cancel();
    _recoveryTimer?.cancel();
    super.dispose();
  }

  void _onJoinPressed(FederationSelector fed, bool recovering) {
    _setSelectedFederation(fed, recovering);
    _refreshFederations();
  }

  void _setSelectedFederation(FederationSelector fed, bool recovering) {
    setState(() {
      _selectedFederation = fed;
      _isRecovering = recovering;
    });
    _recoveryTimer?.cancel();
  }

  Future<void> _refreshFederations() async {
    final feds = await federations();
    setState(() {
      _feds = feds;
      _refreshTrigger++;
    });
  }

  void _onScanPressed(BuildContext context) async {
    final result = await Navigator.push<(FederationSelector, bool)>(
      context,
      MaterialPageRoute(builder: (context) => ScanQRPage(onPay: _onJoinPressed)),
    );

    if (result != null) {
      _setSelectedFederation(result.$1, result.$2);
      _refreshFederations();
      ToastService().show(
        message: "Joined ${result.$1.federationName}",
        duration: const Duration(seconds: 5),
        onTap: () {},
        icon: Icon(Icons.info),
      );
    } else {
      AppLogger.instance.warn('Scan result is null, not updating federations');
    }
  }

  void _onGettingStarted() {
    setState(() {
      _selectedFederation = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    Widget bodyContent;

    if (_selectedFederation != null) {
      bodyContent = Dashboard(
        key: ValueKey(_selectedFederation!.federationId),
        fed: _selectedFederation!,
        recovering: _isRecovering!,
      );
    } else {
      if (recoverFederations) {
        bodyContent = Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(_recoveryStatus, style: const TextStyle(fontSize: 16), textAlign: TextAlign.center),
              const SizedBox(height: 16),
              if (_recoverySecondsRemaining <= 15)
                Text(
                  "Peer might be offline, trying for $_recoverySecondsRemaining more seconds...",
                  style: const TextStyle(fontSize: 16, color: Colors.red, fontWeight: FontWeight.w600),
                  textAlign: TextAlign.center,
                ),
            ],
          ),
        );
      } else {
        bodyContent = Discover(onJoin: _onJoinPressed);
      }
    }

    return ChangeNotifierProvider(
      create: (_) => PreferencesProvider(),
      child: MaterialApp(
        title: 'Ecash App',
        debugShowCheckedModeBanner: false,
        theme: cypherpunkNinjaTheme,
        navigatorKey: _navigatorKey,
        home: Builder(
          builder:
              (innerContext) => Scaffold(
                appBar: AppBar(
                  actions: [
                    IconButton(
                      icon: const Icon(Icons.qr_code_scanner),
                      tooltip: 'Scan',
                      constraints: const BoxConstraints(minWidth: 56, minHeight: 56),
                      onPressed: () => _onScanPressed(innerContext),
                    ),
                  ],
                ),
                drawer: SafeArea(
                  child: FederationSidebar(
                    key: ValueKey(_refreshTrigger),
                    initialFederations: _feds,
                    onFederationSelected: _setSelectedFederation,
                    onLeaveFederation: _leaveFederation,
                    onSettingsPressed: () {
                      Navigator.push(
                        innerContext,
                        MaterialPageRoute(
                          builder:
                              (context) => SettingsScreen(onJoin: _onJoinPressed, onGettingStarted: _onGettingStarted),
                        ),
                      );
                    },
                  ),
                ),
                body: SafeArea(child: bodyContent),
              ),
        ),
      ),
    );
  }
}
