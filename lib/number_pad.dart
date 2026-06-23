import 'package:ecashapp/app.dart';
import 'package:ecashapp/db.dart';
import 'package:ecashapp/ecash_send.dart';
import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/onchain_send.dart';
import 'package:ecashapp/pay_preview.dart';
import 'package:ecashapp/providers/preferences_provider.dart';
import 'package:ecashapp/request.dart';
import 'package:ecashapp/theme.dart';
import 'package:ecashapp/toast.dart';
import 'package:ecashapp/utils.dart';
import 'package:ecashapp/utils/amount_validation.dart';
import 'package:ecashapp/models.dart';
import 'package:flutter/material.dart';
import 'package:ecashapp/widgets/numpad/custom_numpad.dart';
import 'package:ecashapp/widgets/numpad/numpad_button.dart';
import 'package:ecashapp/widgets/federation_picker.dart';
import 'package:ecashapp/widgets/gateway_picker.dart';
import 'package:ecashapp/widgets/protocol_badge.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

enum WithdrawalMode { specificAmount, maxBalance }

class NumberPad extends StatefulWidget {
  final FederationSelector fed;
  final PaymentType paymentType;
  final Map<FiatCurrency, double> btcPrices;
  final VoidCallback? onWithdrawCompleted;
  final String? bitcoinAddress;
  final String? lightningAddressOrLnurl;
  const NumberPad({
    super.key,
    required this.fed,
    required this.paymentType,
    required this.btcPrices,
    this.onWithdrawCompleted,
    this.bitcoinAddress,
    this.lightningAddressOrLnurl,
  });

  @override
  State<NumberPad> createState() => _NumberPadState();
}

class _NumberPadState extends State<NumberPad> {
  final FocusNode _numpadFocus = FocusNode();

  late FederationSelector _selectedFed;
  List<(FederationSelector, bool)>? _allFederations;

  String _rawAmount = '';
  bool _creating = false;
  bool _loadingMax = false;
  bool _loadingBalance = true;
  BigInt? _currentBalance;
  FederationMeta? _federationMeta;
  WithdrawalMode _withdrawalMode = WithdrawalMode.specificAmount;
  bool _isFiatInputMode = false;
  String? _displayedFiatInput;
  String? _preservedSatsBeforeFiatEdit;

  List<FedimintGateway>? _receiveGateways;
  String? _selectedGatewayEndpoint;
  bool? _selectedGatewayIsLnv2;

  // When true, fees are added on top of the invoice so the sender pays them and
  // the receiver gets the full requested amount. When false, the invoice is for
  // the exact requested amount and the receiver absorbs the fees. Resets to true
  // each time the screen opens. Only relevant for Lightning receive.
  bool _includeFees = true;

  // The toggle only makes sense when generating a Lightning invoice to receive,
  // not when paying a Lightning Address / LNURL or for ecash / on-chain.
  bool get _isLightningReceive =>
      widget.paymentType == PaymentType.lightning &&
      widget.lightningAddressOrLnurl == null;

  @override
  void initState() {
    super.initState();
    _selectedFed = widget.fed;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _numpadFocus.requestFocus();
    });

    _fetchBalance();
    _fetchFederationMeta();
    _fetchAllFederations();
    if (_isGeneratingLnInvoice()) {
      _fetchReceiveGateways();
    }
  }

  Future<void> _fetchReceiveGateways() async {
    try {
      final gateways = await listGateways(
        federationId: _selectedFed.federationId,
      );
      if (!mounted) return;
      setState(() {
        _receiveGateways = gateways;
        _selectedGatewayEndpoint =
            gateways.isNotEmpty ? gateways.first.endpoint : null;
        _selectedGatewayIsLnv2 =
            gateways.isNotEmpty ? gateways.first.isLnv2 : null;
      });
    } catch (e) {
      AppLogger.instance.error('Failed to fetch receive gateways: $e');
      if (!mounted) return;
      setState(() {
        _receiveGateways = const [];
        _selectedGatewayEndpoint = null;
        _selectedGatewayIsLnv2 = null;
      });
    }
  }

  FedimintGateway? get _selectedReceiveGateway {
    final list = _receiveGateways;
    if (list == null || list.isEmpty) return null;
    final endpoint = _selectedGatewayEndpoint;
    final isLnv2 = _selectedGatewayIsLnv2;
    if (endpoint == null || isLnv2 == null) return list.first;
    return list.firstWhere(
      (g) => g.endpoint == endpoint && g.isLnv2 == isLnv2,
      orElse: () => list.first,
    );
  }

  Future<void> _fetchBalance() async {
    try {
      final balanceMsats = await balance(
        federationId: _selectedFed.federationId,
      );
      setState(() {
        _currentBalance = balanceMsats;
        _loadingBalance = false;
      });
    } catch (e) {
      AppLogger.instance.error('Failed to fetch balance for number pad: $e');
      setState(() {
        _loadingBalance = false;
      });
    }
  }

  Future<void> _fetchFederationMeta() async {
    try {
      final meta = await getFederationMeta(
        federationId: _selectedFed.federationId,
      );
      setState(() {
        _federationMeta = meta;
      });
    } catch (e) {
      AppLogger.instance.error('Failed to fetch federation metadata: $e');
    }
  }

  Future<void> _fetchAllFederations() async {
    try {
      final feds = await federations();
      if (mounted) {
        setState(() {
          _allFederations = feds;
        });
      }
    } catch (e) {
      AppLogger.instance.error('Failed to fetch federations: $e');
    }
  }

  Future<void> _onFederationCardTapped() async {
    final feds = _allFederations;
    if (feds == null || feds.length <= 1) return;

    final selected = await showFederationPicker(
      context: context,
      federations: feds,
      title: context.l10n.selectMint,
    );

    if (selected != null && mounted) {
      setState(() {
        _selectedFed = selected.$1;
        _currentBalance = null;
        _loadingBalance = true;
        _federationMeta = null;
        _withdrawalMode = WithdrawalMode.specificAmount;
        _receiveGateways = null;
        _selectedGatewayEndpoint = null;
        _selectedGatewayIsLnv2 = null;
      });
      _fetchBalance();
      _fetchFederationMeta();
      if (_isGeneratingLnInvoice()) {
        _fetchReceiveGateways();
      }
    }
  }

  @override
  void dispose() {
    _numpadFocus.dispose();
    super.dispose();
  }

  String _formatAmount(String value, BitcoinDisplay bitcoinDisplay) {
    BigInt displayValue;
    try {
      if (value.isEmpty) {
        displayValue = BigInt.zero;
      } else {
        displayValue = BigInt.parse(value);
      }
    } catch (_) {
      displayValue = BigInt.zero;
    }

    return formatBalance(
      displayValue * BigInt.from(1000),
      false,
      bitcoinDisplay,
    );
  }

  bool _isGeneratingLnInvoice() =>
      widget.paymentType == PaymentType.lightning &&
      widget.lightningAddressOrLnurl == null;

  bool _isValidAmount() => isValidAmount(
    rawAmount: _rawAmount,
    loadingBalance: _loadingBalance,
    currentBalance: _currentBalance,
    paymentType: widget.paymentType,
    generatingLnInvoice: _isGeneratingLnInvoice(),
  );

  bool _isAmountOverBalance() => isAmountOverBalance(
    rawAmount: _rawAmount,
    loadingBalance: _loadingBalance,
    currentBalance: _currentBalance,
    generatingLnInvoice: _isGeneratingLnInvoice(),
  );

  BigInt? _getRemainingBalance() => getRemainingBalance(
    rawAmount: _rawAmount,
    loadingBalance: _loadingBalance,
    currentBalance: _currentBalance,
  );

  bool _canAddFiatDigit() => canAddFiatDigit(_displayedFiatInput);

  void _onSwapCurrency() {
    final fiatCurrency = context.read<PreferencesProvider>().fiatCurrency;
    final btcPrice = widget.btcPrices[fiatCurrency];

    // Don't allow swap if price data unavailable
    if (btcPrice == null) {
      ToastService().show(
        message: context.l10n.priceDataUnavailable,
        duration: const Duration(seconds: 3),
        onTap: () {},
        icon: const Icon(Icons.warning),
      );
      return;
    }

    setState(() {
      if (_isFiatInputMode) {
        // Swapping FROM fiat TO bitcoin
        // If user didn't edit in fiat mode, restore preserved value
        if (_preservedSatsBeforeFiatEdit != null) {
          _rawAmount = _preservedSatsBeforeFiatEdit!;
        }
        // _rawAmount already contains converted sats if user typed in fiat
        _displayedFiatInput = null;
        _preservedSatsBeforeFiatEdit = null;
        _isFiatInputMode = false;
      } else {
        // Swapping FROM bitcoin TO fiat
        // Preserve the current sats value
        _preservedSatsBeforeFiatEdit = _rawAmount;
        // Calculate and display the fiat equivalent
        final sats = int.tryParse(_rawAmount) ?? 0;
        final fiatValue = (btcPrice * sats) / 100000000;
        // Store as raw fiat input (just the number, formatted on display)
        // Only strip .00 to allow typing, but keep meaningful decimals
        String fiatStr = fiatValue.toStringAsFixed(2);
        if (fiatStr.endsWith('.00')) {
          fiatStr = fiatStr.substring(0, fiatStr.length - 3); // Remove .00 only
        }
        _displayedFiatInput = fiatStr;
        _isFiatInputMode = true;
      }
    });
  }

  Future<void> _onMaxPressed() async {
    if (widget.paymentType == PaymentType.lightning) return;

    setState(() => _loadingMax = true);

    try {
      final balanceMsats = await balance(
        federationId: _selectedFed.federationId,
      );
      final balanceSats = balanceMsats.toSats;

      setState(() {
        _rawAmount = balanceSats.toString();
        _withdrawalMode = WithdrawalMode.maxBalance;
      });
    } catch (e) {
      AppLogger.instance.error('Failed to get balance: $e');
      ToastService().show(
        message: context.l10n.failedToGetBalance,
        duration: const Duration(seconds: 5),
        onTap: () {},
        icon: Icon(Icons.error),
      );
    } finally {
      setState(() => _loadingMax = false);
    }
  }

  Future<void> _handleLightningReceive(BigInt amountSats) async {
    try {
      final requestedAmountMsats = amountSats * BigInt.from(1000);

      final selected = _selectedReceiveGateway;
      if (selected == null) {
        throw Exception('No available gateways');
      }

      final receiveAmount = await computeReceiveAmountWithFees(
        federationId: _selectedFed.federationId,
        gatewayUrl: selected.endpoint,
        isLnv2: selected.isLnv2,
        amountMsats: requestedAmountMsats,
        includeFees: _includeFees,
      );

      // Create the invoice
      final invoice = await receive(
        federationId: _selectedFed.federationId,
        amountMsatsWithFees: receiveAmount.invoiceMsats,
        amountMsatsWithoutFees: requestedAmountMsats,
        federationFeeMsats: receiveAmount.federationFeeMsats,
        gatewayFeeMsats: receiveAmount.gatewayFeeMsats,
        gateway: selected.endpoint,
        isLnv2: selected.isLnv2,
      );

      invoicePaidToastVisible.value = false;

      // Only show modal on success
      await showAppModalBottomSheet(
        context: context,
        childBuilder: () async {
          return Request(
            invoice: invoice.$1,
            fed: _selectedFed,
            operationId: invoice.$2,
            requestedAmountMsats: requestedAmountMsats,
            totalMsats: receiveAmount.invoiceMsats,
            federationFeeMsats: receiveAmount.federationFeeMsats,
            gatewayFeeMsats: receiveAmount.gatewayFeeMsats,
            gateway: selected.endpoint,
            pubkey: invoice.$3,
            paymentHash: invoice.$4,
            expiry: invoice.$5,
          );
        },
      );
    } catch (e) {
      AppLogger.instance.error("Could not create invoice: $e");

      String errorMessage = context.l10n.couldNotCreateInvoice;
      if (e.toString().contains("No available gateways")) {
        errorMessage = context.l10n.noGatewaysAvailable;
      }

      ToastService().show(
        message: errorMessage,
        duration: const Duration(seconds: 5),
        onTap: () {},
        icon: Icon(Icons.error),
      );
    } finally {
      invoicePaidToastVisible.value = true;
    }
  }

  Future<void> _onConfirm() async {
    setState(() => _creating = true);
    final amountSats = BigInt.tryParse(_rawAmount);
    if (amountSats != null) {
      if (widget.paymentType == PaymentType.lightning) {
        if (widget.lightningAddressOrLnurl != null) {
          final amountMsats = amountSats * BigInt.from(1000);

          // Check balance first
          final fedBalance = await balance(
            federationId: _selectedFed.federationId,
          );
          if (amountMsats > fedBalance) {
            ToastService().show(
              message: context.l10n.balanceTooLow,
              duration: const Duration(seconds: 5),
              onTap: () {},
              icon: Icon(Icons.warning),
            );
            setState(() {
              _creating = false;
            });
            return;
          }

          await showAppModalBottomSheet(
            context: context,
            errorMessage: context.l10n.couldNotReachLnAddress,
            childBuilder: () async {
              // Get invoice from LN Address
              final invoice = await getInvoiceFromLnaddressOrLnurl(
                amountMsats: amountMsats,
                lnaddressOrLnurl: widget.lightningAddressOrLnurl!,
              );

              // Get and show payment preview
              final preview = await paymentPreviewWithGateways(
                federationId: _selectedFed.federationId,
                bolt11: invoice,
              );

              return PaymentPreviewWidget(
                fed: _selectedFed,
                previewData: preview,
                federations: _allFederations ?? await federations(),
              );
            },
          );
        } else {
          await _handleLightningReceive(amountSats);
        }
      } else if (widget.paymentType == PaymentType.ecash) {
        showAppModalBottomSheet(
          context: context,
          childBuilder: () async {
            BigInt amount = amountSats * BigInt.from(1000);
            if (_withdrawalMode == WithdrawalMode.maxBalance) {
              amount = await balance(federationId: _selectedFed.federationId);
            }
            return EcashSend(fed: _selectedFed, amountMsats: amount);
          },
        );
      } else if (widget.paymentType == PaymentType.onchain) {
        showAppModalBottomSheet(
          context: context,
          childBuilder: () async {
            return OnchainSend(
              fed: _selectedFed,
              amountSats: amountSats,
              withdrawalMode: _withdrawalMode,
              onWithdrawCompleted: widget.onWithdrawCompleted,
              defaultAddress: widget.bitcoinAddress,
            );
          },
        );
      }
    }
    setState(() => _creating = false);
  }

  void _handleKeyEvent(KeyEvent event) {
    // only handle on key down
    if (event is KeyDownEvent) {
      final key = event.logicalKey;
      // Handle Enter for confirm
      if (key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter) {
        _onConfirm();
        return;
      }

      String digit = '';
      if (key == LogicalKeyboardKey.digit0 ||
          key == LogicalKeyboardKey.numpad0) {
        digit = '0';
      }
      if (key == LogicalKeyboardKey.digit1 ||
          key == LogicalKeyboardKey.numpad1) {
        digit = '1';
      }
      if (key == LogicalKeyboardKey.digit2 ||
          key == LogicalKeyboardKey.numpad2) {
        digit = '2';
      }
      if (key == LogicalKeyboardKey.digit3 ||
          key == LogicalKeyboardKey.numpad3) {
        digit = '3';
      }
      if (key == LogicalKeyboardKey.digit4 ||
          key == LogicalKeyboardKey.numpad4) {
        digit = '4';
      }
      if (key == LogicalKeyboardKey.digit5 ||
          key == LogicalKeyboardKey.numpad5) {
        digit = '5';
      }
      if (key == LogicalKeyboardKey.digit6 ||
          key == LogicalKeyboardKey.numpad6) {
        digit = '6';
      }
      if (key == LogicalKeyboardKey.digit7 ||
          key == LogicalKeyboardKey.numpad7) {
        digit = '7';
      }
      if (key == LogicalKeyboardKey.digit8 ||
          key == LogicalKeyboardKey.numpad8) {
        digit = '8';
      }
      if (key == LogicalKeyboardKey.digit9 ||
          key == LogicalKeyboardKey.numpad9) {
        digit = '9';
      }
      if (key == LogicalKeyboardKey.backspace) {
        setState(() {
          if (_isFiatInputMode) {
            if (_displayedFiatInput != null &&
                _displayedFiatInput!.isNotEmpty) {
              _displayedFiatInput = _displayedFiatInput!.substring(
                0,
                _displayedFiatInput!.length - 1,
              );
              _preservedSatsBeforeFiatEdit = null;
              final fiatValue =
                  double.tryParse(_displayedFiatInput ?? '0') ?? 0;
              final fiatCurrency =
                  context.read<PreferencesProvider>().fiatCurrency;
              final btcPrice = widget.btcPrices[fiatCurrency];
              _rawAmount =
                  calculateSatsFromFiat(btcPrice, fiatValue).toString();
            }
          } else {
            if (_rawAmount.isNotEmpty) {
              _rawAmount = _rawAmount.substring(0, _rawAmount.length - 1);
            }
          }
          _withdrawalMode = WithdrawalMode.specificAmount;
        });
      }
      // Handle decimal point for fiat mode via keyboard
      if (_isFiatInputMode &&
          (key == LogicalKeyboardKey.period ||
              key == LogicalKeyboardKey.numpadDecimal)) {
        setState(() {
          if (!(_displayedFiatInput?.contains('.') ?? false)) {
            _preservedSatsBeforeFiatEdit = null;
            _displayedFiatInput = '${_displayedFiatInput ?? ''}.';
          }
        });
      }
      if (digit != '') {
        setState(() {
          if (_isFiatInputMode) {
            // Don't allow more than 2 decimal places
            if (!_canAddFiatDigit()) return;
            _preservedSatsBeforeFiatEdit = null;
            // Replace leading zero instead of appending
            if (_displayedFiatInput == '0') {
              _displayedFiatInput = digit;
            } else {
              _displayedFiatInput = (_displayedFiatInput ?? '') + digit;
            }
            final fiatValue = double.tryParse(_displayedFiatInput ?? '0') ?? 0;
            final fiatCurrency =
                context.read<PreferencesProvider>().fiatCurrency;
            final btcPrice = widget.btcPrices[fiatCurrency];
            _rawAmount = calculateSatsFromFiat(btcPrice, fiatValue).toString();
          } else {
            _rawAmount += digit;
          }
          _withdrawalMode = WithdrawalMode.specificAmount;
        });
      }
    }
  }

  Widget _buildFederationCard() {
    // Hide card for lightning receives
    final isLightningReceive =
        widget.paymentType == PaymentType.lightning &&
        widget.lightningAddressOrLnurl == null;

    if (isLightningReceive) {
      return const SizedBox.shrink();
    }

    final remainingBalance = _getRemainingBalance();
    final isOverBalance = _isAmountOverBalance();
    final theme = Theme.of(context);
    final bitcoinDisplay = context.select<PreferencesProvider, BitcoinDisplay>(
      (prefs) => prefs.bitcoinDisplay,
    );

    final hasMultipleFeds = (_allFederations?.length ?? 0) > 1;

    return Center(
      child: GestureDetector(
        onTap: hasMultipleFeds ? _onFederationCardTapped : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          constraints: const BoxConstraints(maxWidth: 400),
          margin: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color:
                  isOverBalance
                      ? Colors.red.withValues(alpha: 0.4)
                      : theme.colorScheme.primary.withValues(alpha: 0.1),
              width: 1,
            ),
            boxShadow: [
              if (isOverBalance)
                BoxShadow(
                  color: Colors.red.withValues(alpha: 0.2),
                  blurRadius: 12,
                  spreadRadius: 2,
                  offset: const Offset(0, 2),
                )
              else
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
            ],
          ),
          child: Row(
            children: [
              // Federation Image
              ClipRRect(
                borderRadius: BorderRadius.circular(28),
                child: SizedBox(
                  width: 56,
                  height: 56,
                  child:
                      _federationMeta?.picture != null &&
                              _federationMeta!.picture!.isNotEmpty
                          ? Image.network(
                            _federationMeta!.picture!,
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) {
                              return Image.asset(
                                'assets/images/fedimint-icon-color.png',
                                fit: BoxFit.cover,
                              );
                            },
                          )
                          : Image.asset(
                            'assets/images/fedimint-icon-color.png',
                            fit: BoxFit.cover,
                          ),
                ),
              ),
              const SizedBox(width: 12),
              // Federation Name and Balance
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _selectedFed.federationName,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      context.l10n.available,
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                    const SizedBox(height: 2),
                    remainingBalance == null
                        ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.grey,
                          ),
                        )
                        : AnimatedDefaultTextStyle(
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeInOut,
                          style: TextStyle(
                            fontSize: 14,
                            color: isOverBalance ? Colors.red : Colors.grey,
                          ),
                          child: Text(
                            formatBalance(
                              remainingBalance,
                              false,
                              bitcoinDisplay,
                            ),
                          ),
                        ),
                  ],
                ),
              ),
              if (hasMultipleFeds)
                Icon(Icons.unfold_more, color: Colors.grey[500], size: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGatewayCard() {
    if (!_isGeneratingLnInvoice()) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final bitcoinDisplay = context.select<PreferencesProvider, BitcoinDisplay>(
      (prefs) => prefs.bitcoinDisplay,
    );
    final gateways = _receiveGateways;
    final selected = _selectedReceiveGateway;
    final canTap = gateways != null && gateways.isNotEmpty;

    return Center(
      child: GestureDetector(
        onTap: canTap ? _onGatewayCardTapped : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          constraints: const BoxConstraints(maxWidth: 400),
          margin: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: theme.colorScheme.primary.withValues(alpha: 0.1),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            children: [
              Icon(
                Icons.device_hub,
                color: theme.colorScheme.primary,
                size: 28,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      context.l10n.gateway,
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                    const SizedBox(height: 4),
                    if (gateways == null)
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.grey,
                        ),
                      )
                    else if (selected == null)
                      Text(
                        context.l10n.noGatewaysAvailableShort,
                        style: const TextStyle(
                          fontSize: 14,
                          color: Colors.grey,
                        ),
                      )
                    else ...[
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              selected.lightningAlias ?? selected.endpoint,
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          ProtocolBadge(isLnv2: selected.isLnv2),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${formatBalance(selected.baseRoutingFee, true, bitcoinDisplay)} + ${selected.ppmRoutingFee} ppm',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (canTap)
                Icon(Icons.unfold_more, color: Colors.grey[500], size: 20),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _onGatewayCardTapped() async {
    final gateways = _receiveGateways;
    if (gateways == null || gateways.isEmpty) return;

    final currentIndex = gateways.indexWhere(
      (g) =>
          g.endpoint == _selectedGatewayEndpoint &&
          g.isLnv2 == _selectedGatewayIsLnv2,
    );
    final pickedIndex = await showGatewayPickerSheet(
      context,
      gateways: gateways,
      selectedIndex: currentIndex >= 0 ? currentIndex : 0,
    );

    if (pickedIndex != null && mounted) {
      final picked = gateways[pickedIndex];
      setState(() {
        _selectedGatewayEndpoint = picked.endpoint;
        _selectedGatewayIsLnv2 = picked.isLnv2;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bitcoinDisplay = context.select<PreferencesProvider, BitcoinDisplay>(
      (prefs) => prefs.bitcoinDisplay,
    );
    final fiatCurrency = context.select<PreferencesProvider, FiatCurrency>(
      (prefs) => prefs.fiatCurrency,
    );
    final fiatText = calculateFiatValue(
      widget.btcPrices[fiatCurrency],
      int.tryParse(_rawAmount) ?? 0,
      fiatCurrency,
    );

    return SafeArea(
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            context.l10n.enterAmount,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          centerTitle: true,
          backgroundColor: Colors.transparent,
          elevation: 0,
        ),
        body: Column(
          children: [
            _buildFederationCard(),
            _buildGatewayCard(),
            Expanded(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Primary display (large) - shows what user is entering
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      transitionBuilder: (child, animation) {
                        return FadeTransition(
                          opacity: animation,
                          child: SlideTransition(
                            position: Tween<Offset>(
                              begin: const Offset(0, 0.2),
                              end: Offset.zero,
                            ).animate(animation),
                            child: child,
                          ),
                        );
                      },
                      child: RichText(
                        key: ValueKey<bool>(_isFiatInputMode),
                        text: TextSpan(
                          style: const TextStyle(color: Colors.white),
                          children: [
                            TextSpan(
                              text:
                                  _isFiatInputMode
                                      ? formatFiatInput(
                                        _displayedFiatInput ?? '0',
                                        fiatCurrency,
                                      )
                                      : _formatAmount(
                                        _rawAmount,
                                        bitcoinDisplay,
                                      ),
                              style: const TextStyle(
                                fontSize: 48,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    // Secondary display row with swap button (fixed position)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        // Spacer to balance the swap button on the right
                        const SizedBox(width: 36),
                        // Secondary currency display (small) - fixed width centered
                        SizedBox(
                          width: 150,
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 200),
                            transitionBuilder: (child, animation) {
                              return FadeTransition(
                                opacity: animation,
                                child: SlideTransition(
                                  position: Tween<Offset>(
                                    begin: const Offset(0, -0.2),
                                    end: Offset.zero,
                                  ).animate(animation),
                                  child: child,
                                ),
                              );
                            },
                            child: Text(
                              key: ValueKey<bool>(_isFiatInputMode),
                              _isFiatInputMode
                                  ? _formatAmount(_rawAmount, bitcoinDisplay)
                                  : fiatText,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 24,
                                color: Colors.grey,
                              ),
                            ),
                          ),
                        ),
                        // Swap button - fixed width (hidden when price unavailable)
                        widget.btcPrices[fiatCurrency] != null
                            ? SizedBox(
                              width: 36,
                              child: IconButton(
                                onPressed: _onSwapCurrency,
                                icon: const Icon(
                                  Icons.swap_vert,
                                  color: Colors.grey,
                                  size: 28,
                                ),
                                tooltip: context.l10n.swapInputCurrency,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                              ),
                            )
                            : const SizedBox(
                              width: 36,
                            ), // Empty spacer to maintain layout
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (_isLightningReceive)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        context.l10n.addFeesToInvoice,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                    Tooltip(
                      message: context.l10n.addFeesToInvoiceDescription,
                      triggerMode: TooltipTriggerMode.tap,
                      showDuration: const Duration(seconds: 4),
                      child: Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Icon(
                          Icons.info_outline,
                          size: 18,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    Switch(
                      value: _includeFees,
                      activeThumbColor: Theme.of(context).colorScheme.primary,
                      onChanged: (value) {
                        setState(() => _includeFees = value);
                      },
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _isValidAmount() ? _onConfirm : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF42CFFF),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child:
                      _creating
                          ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                Colors.black,
                              ),
                            ),
                          )
                          : Text(
                            context.l10n.confirm,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            KeyboardListener(
              focusNode: _numpadFocus,
              onKeyEvent: _handleKeyEvent,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: CustomNumPad(
                  onDigitPressed: (digit) {
                    setState(() {
                      if (_isFiatInputMode) {
                        // Don't allow more than 2 decimal places
                        if (!_canAddFiatDigit()) return;

                        // Clear preserved sats since user is now editing
                        _preservedSatsBeforeFiatEdit = null;

                        // Replace leading zero instead of appending
                        if (_displayedFiatInput == '0') {
                          _displayedFiatInput = digit.toString();
                        } else {
                          _displayedFiatInput =
                              (_displayedFiatInput ?? '') + digit.toString();
                        }

                        // Convert to sats
                        final fiatValue =
                            double.tryParse(_displayedFiatInput ?? '0') ?? 0;
                        final fiatCurrency =
                            context.read<PreferencesProvider>().fiatCurrency;
                        final btcPrice = widget.btcPrices[fiatCurrency];
                        final sats = calculateSatsFromFiat(btcPrice, fiatValue);
                        _rawAmount = sats.toString();
                      } else {
                        // In bitcoin mode (existing behavior)
                        _rawAmount += digit.toString();
                      }
                      _withdrawalMode = WithdrawalMode.specificAmount;
                    });
                  },
                  onBackspace: () {
                    setState(() {
                      if (_isFiatInputMode) {
                        if (_displayedFiatInput != null &&
                            _displayedFiatInput!.isNotEmpty) {
                          _displayedFiatInput = _displayedFiatInput!.substring(
                            0,
                            _displayedFiatInput!.length - 1,
                          );
                          _preservedSatsBeforeFiatEdit = null;
                          // Recalculate sats
                          final fiatValue =
                              double.tryParse(_displayedFiatInput ?? '0') ?? 0;
                          final fiatCurrency =
                              context.read<PreferencesProvider>().fiatCurrency;
                          final btcPrice = widget.btcPrices[fiatCurrency];
                          _rawAmount =
                              calculateSatsFromFiat(
                                btcPrice,
                                fiatValue,
                              ).toString();
                        }
                      } else {
                        if (_rawAmount.isNotEmpty) {
                          _rawAmount = _rawAmount.substring(
                            0,
                            _rawAmount.length - 1,
                          );
                        }
                      }
                      _withdrawalMode = WithdrawalMode.specificAmount;
                    });
                  },
                  leftWidget:
                      _isFiatInputMode
                          ? NumPadButton(
                            label: '.',
                            onPressed: () {
                              setState(() {
                                // Only add decimal if not already present
                                if (!(_displayedFiatInput?.contains('.') ??
                                    false)) {
                                  _preservedSatsBeforeFiatEdit = null;
                                  _displayedFiatInput =
                                      '${_displayedFiatInput ?? ''}.';
                                }
                              });
                            },
                            isSpecial: true,
                          )
                          : null,
                  onLeftAction:
                      !_isFiatInputMode &&
                              (widget.paymentType == PaymentType.onchain ||
                                  widget.paymentType == PaymentType.ecash)
                          ? (_loadingMax ? null : _onMaxPressed)
                          : null,
                  leftActionLoading: _loadingMax,
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}
