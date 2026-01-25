import 'dart:async';

import 'package:ecashapp/contacts/contacts_screen.dart';
import 'package:ecashapp/deep_link_handler.dart';
import 'package:ecashapp/discover.dart';
import 'package:ecashapp/models.dart';
import 'package:ecashapp/number_pad.dart';
import 'package:ecashapp/onchain_send.dart';
import 'package:ecashapp/pay_preview.dart';
import 'package:ecashapp/screens/dashboard.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/providers/preferences_provider.dart';
import 'package:ecashapp/scan.dart';
import 'package:ecashapp/setttings.dart';
import 'package:ecashapp/sidebar.dart';
import 'package:ecashapp/theme.dart';
import 'package:ecashapp/toast.dart';
import 'package:ecashapp/utils.dart';
import 'package:ecashapp/widgets/federation_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

final invoicePaidToastVisible = ValueNotifier<bool>(true);

class MyApp extends StatefulWidget {
  final List<(FederationSelector, bool)> initialFederations;
  final bool recoverFederationInviteCodes;
  const MyApp({
    super.key,
    required this.initialFederations,
    required this.recoverFederationInviteCodes,
  });

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
  StreamSubscription<DeepLinkData>? _deepLinkSubscription;

  final GlobalKey<NavigatorState> _navigatorKey = ToastService().navigatorKey;

  bool recoverFederations = false;
  bool _processingDeepLink = false;

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

    // Subscribe to deep links (warm start)
    _deepLinkSubscription = DeepLinkHandler().deepLinkStream.listen((deepLink) {
      _handleDeepLink(deepLink);
    });

    // Check for pending deep link (cold start) after frame is rendered
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkPendingDeepLink();
    });

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
          icon: Icon(
            Icons.currency_bitcoin,
            color: Theme.of(context).colorScheme.primary,
          ),
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
              _recoveryStatus =
                  "Trying to re-join ${event.field0} using peer ${event.field1}...";
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
    final federationIdString = await federationIdToString(
      federationId: federationId,
    );

    FederationSelector? selector;
    bool? recovering;

    for (var sel in _feds) {
      final idString = await federationIdToString(
        federationId: sel.$1.federationId,
      );
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
    _deepLinkSubscription?.cancel();
    _recoveryTimer?.cancel();
    super.dispose();
  }

  void _checkPendingDeepLink() {
    final pendingDeepLink = DeepLinkHandler().pendingDeepLink;
    if (pendingDeepLink != null) {
      DeepLinkHandler().clearPendingDeepLink();
      _handleDeepLink(pendingDeepLink);
    }
  }

  Future<void> _handleDeepLink(DeepLinkData deepLink) async {
    if (_processingDeepLink) {
      AppLogger.instance.warn('Already processing a deep link, ignoring');
      return;
    }

    if (_feds.isEmpty) {
      AppLogger.instance.warn('No federations available for deep link');
      ToastService().show(
        message: 'Please join a federation first',
        duration: const Duration(seconds: 5),
        onTap: () {},
        icon: const Icon(Icons.warning, color: Colors.amber),
      );
      return;
    }

    _processingDeepLink = true;
    AppLogger.instance.info('Handling deep link: $deepLink');

    try {
      final context = _navigatorKey.currentContext;
      if (context == null) {
        AppLogger.instance.error('No context available for deep link');
        return;
      }

      // Show federation picker if multiple federations
      final selectedFed = await showFederationPicker(
        context: context,
        federations: _feds,
        title:
            deepLink.type == DeepLinkType.lightning
                ? 'Select Federation to Pay From'
                : 'Select Federation',
      );

      if (selectedFed == null) {
        AppLogger.instance.info('User cancelled federation selection');
        return;
      }

      final (fed, recovering) = selectedFed;

      if (recovering) {
        ToastService().show(
          message: 'Cannot send payments while federation is recovering',
          duration: const Duration(seconds: 5),
          onTap: () {},
          icon: const Icon(Icons.warning, color: Colors.amber),
        );
        return;
      }

      // Parse the payment data using the existing Rust parser
      final result = await parseScannedTextForFederation(
        text: deepLink.data,
        federation: fed,
      );

      final action = result.$1;

      switch (action) {
        case ParsedText_LightningInvoice(:final field0):
          // Show payment preview for BOLT11 invoice
          if (!mounted) return;
          await showAppModalBottomSheet(
            context: context,
            childBuilder: () async {
              final preview = await paymentPreview(
                federationId: fed.federationId,
                bolt11: field0,
              );
              return PaymentPreviewWidget(fed: fed, paymentPreview: preview);
            },
          );
          _onJoinPressed(fed, false);
          break;

        case ParsedText_LightningAddressOrLnurl(:final field0):
          // For LNURL/Lightning Address, go to number pad for amount entry
          final btcPrices = await fetchAllBtcPrices();
          if (!mounted) return;
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder:
                  (_) => NumberPad(
                    fed: fed,
                    paymentType: PaymentType.lightning,
                    btcPrices: btcPrices,
                    onWithdrawCompleted: null,
                    lightningAddressOrLnurl: field0,
                  ),
            ),
          );
          break;

        case ParsedText_BitcoinAddress(:final field0, :final field1):
          // For Bitcoin addresses, route to on-chain withdrawal
          if (field1 != null) {
            // Amount specified in BIP21 URI
            if (!mounted) return;
            await showAppModalBottomSheet(
              context: context,
              childBuilder: () async {
                return OnchainSend(
                  fed: fed,
                  amountSats: field1.toSats,
                  withdrawalMode: WithdrawalMode.specificAmount,
                  defaultAddress: field0,
                );
              },
            );
          } else {
            // No amount specified, go to number pad
            final btcPrices = await fetchAllBtcPrices();
            if (!mounted) return;
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder:
                    (_) => NumberPad(
                      fed: fed,
                      paymentType: PaymentType.onchain,
                      btcPrices: btcPrices,
                      onWithdrawCompleted: null,
                      bitcoinAddress: field0,
                    ),
              ),
            );
          }
          _onJoinPressed(fed, false);
          break;

        default:
          AppLogger.instance.warn('Unsupported deep link type: $action');
          ToastService().show(
            message: 'Unsupported payment type',
            duration: const Duration(seconds: 5),
            onTap: () {},
            icon: const Icon(Icons.error, color: Colors.red),
          );
      }
    } catch (e) {
      AppLogger.instance.error('Error handling deep link: $e');
      ToastService().show(
        message: 'Failed to process payment link',
        duration: const Duration(seconds: 5),
        onTap: () {},
        icon: const Icon(Icons.error, color: Colors.red),
      );
    } finally {
      _processingDeepLink = false;
    }
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
      MaterialPageRoute(
        builder: (context) => ScanQRPage(onPay: _onJoinPressed),
      ),
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
              Text(
                _recoveryStatus,
                style: const TextStyle(fontSize: 16),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              if (_recoverySecondsRemaining <= 15)
                Text(
                  "Peer might be offline, trying for $_recoverySecondsRemaining more seconds...",
                  style: const TextStyle(
                    fontSize: 16,
                    color: Colors.red,
                    fontWeight: FontWeight.w600,
                  ),
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
                      constraints: const BoxConstraints(
                        minWidth: 56,
                        minHeight: 56,
                      ),
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
                    onContactsPressed: () {
                      Navigator.push(
                        innerContext,
                        MaterialPageRoute(
                          builder:
                              (context) => ContactsScreen(
                                selectedFederation: _selectedFederation,
                              ),
                        ),
                      );
                    },
                    onSettingsPressed: () {
                      Navigator.push(
                        innerContext,
                        MaterialPageRoute(
                          builder:
                              (context) => SettingsScreen(
                                onJoin: _onJoinPressed,
                                onGettingStarted: _onGettingStarted,
                              ),
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
