import 'package:ecashapp/app.dart';
import 'package:ecashapp/db.dart';
import 'package:ecashapp/ecash_send.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/onchain_send.dart';
import 'package:ecashapp/pay_preview.dart';
import 'package:ecashapp/providers/preferences_provider.dart';
import 'package:ecashapp/request.dart';
import 'package:ecashapp/theme.dart';
import 'package:ecashapp/toast.dart';
import 'package:ecashapp/utils.dart';
import 'package:ecashapp/models.dart';
import 'package:flutter/material.dart';
import 'package:ecashapp/widgets/numpad/custom_numpad.dart';
import 'package:ecashapp/widgets/numpad/numpad_button.dart';
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

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _numpadFocus.requestFocus();
    });

    _fetchBalance();
    _fetchFederationMeta();
  }

  Future<void> _fetchBalance() async {
    try {
      final balanceMsats = await balance(federationId: widget.fed.federationId);
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
        federationId: widget.fed.federationId,
      );
      setState(() {
        _federationMeta = meta;
      });
    } catch (e) {
      AppLogger.instance.error('Failed to fetch federation metadata: $e');
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

  bool _isValidAmount() {
    // Disable while balance is loading
    if (_loadingBalance) return false;

    // Parse the entered amount
    final amountSats = BigInt.tryParse(_rawAmount);
    if (amountSats == null || amountSats == BigInt.zero) {
      return false;
    }

    // For lightning receives (no address/lnurl), only check amount > 0
    final isLightningReceive =
        widget.paymentType == PaymentType.lightning &&
        widget.lightningAddressOrLnurl == null;

    if (isLightningReceive) {
      return true; // Balance check not needed for receives
    }

    // For sends (lightning with address, ecash, onchain), check balance
    if (_currentBalance != null) {
      final amountMsats = amountSats * BigInt.from(1000);
      return amountMsats <= _currentBalance!;
    }

    // If balance failed to load, allow user to proceed (error will be caught later)
    return true;
  }

  bool _isAmountOverBalance() {
    // Don't show red if still loading or no balance available
    if (_loadingBalance || _currentBalance == null) return false;

    // Parse the entered amount
    final amountSats = BigInt.tryParse(_rawAmount);
    if (amountSats == null || amountSats == BigInt.zero) {
      return false;
    }

    // For lightning receives, balance check doesn't apply
    final isLightningReceive =
        widget.paymentType == PaymentType.lightning &&
        widget.lightningAddressOrLnurl == null;

    if (isLightningReceive) {
      return false;
    }

    // For sends, check if amount exceeds balance
    final amountMsats = amountSats * BigInt.from(1000);
    return amountMsats > _currentBalance!;
  }

  BigInt? _getRemainingBalance() {
    // If balance is loading or unavailable, return null
    if (_loadingBalance || _currentBalance == null) return null;

    // Parse the entered amount
    final amountSats = BigInt.tryParse(_rawAmount);
    if (amountSats == null) {
      return _currentBalance; // No amount entered, show full balance
    }

    final amountMsats = amountSats * BigInt.from(1000);
    final remaining = _currentBalance! - amountMsats;

    // If negative, return zero (will display as "0 sats" in red)
    return remaining < BigInt.zero ? BigInt.zero : remaining;
  }

  /// Returns true if we can add another digit in fiat mode.
  /// Limits to 2 decimal places.
  bool _canAddFiatDigit() {
    if (_displayedFiatInput == null) return true;
    if (!_displayedFiatInput!.contains('.')) return true;
    final parts = _displayedFiatInput!.split('.');
    return parts.length < 2 || parts[1].length < 2;
  }

  void _onSwapCurrency() {
    final fiatCurrency = context.read<PreferencesProvider>().fiatCurrency;
    final btcPrice = widget.btcPrices[fiatCurrency];

    // Don't allow swap if price data unavailable
    if (btcPrice == null) {
      ToastService().show(
        message: "Price data unavailable",
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
        _displayedFiatInput = fiatValue.toStringAsFixed(2);
        _isFiatInputMode = true;
      }
    });
  }

  Future<void> _onMaxPressed() async {
    if (widget.paymentType == PaymentType.lightning) return;

    setState(() => _loadingMax = true);

    try {
      final balanceMsats = await balance(federationId: widget.fed.federationId);
      final balanceSats = balanceMsats.toSats;

      setState(() {
        _rawAmount = balanceSats.toString();
        _withdrawalMode = WithdrawalMode.maxBalance;
      });
    } catch (e) {
      AppLogger.instance.error('Failed to get balance: $e');
      ToastService().show(
        message: "Failed to get balance",
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
      await showAppModalBottomSheet(
        context: context,
        childBuilder: () async {
          final requestedAmountMsats = amountSats * BigInt.from(1000);
          final gateway = await selectReceiveGateway(
            federationId: widget.fed.federationId,
            amountMsats: requestedAmountMsats,
          );
          final contractAmount = gateway.$2;
          final invoice = await receive(
            federationId: widget.fed.federationId,
            amountMsatsWithFees: contractAmount,
            amountMsatsWithoutFees: requestedAmountMsats,
            gateway: gateway.$1,
            isLnv2: gateway.$3,
          );
          invoicePaidToastVisible.value = false;

          return Request(
            invoice: invoice.$1,
            fed: widget.fed,
            operationId: invoice.$2,
            requestedAmountMsats: requestedAmountMsats,
            totalMsats: contractAmount,
            gateway: gateway.$1,
            pubkey: invoice.$3,
            paymentHash: invoice.$4,
            expiry: invoice.$5,
          );
        },
      );
    } catch (e) {
      AppLogger.instance.error("Could not create invoice: $e");
      ToastService().show(
        message: "Could not create invoice",
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
            federationId: widget.fed.federationId,
          );
          if (amountMsats > fedBalance) {
            ToastService().show(
              message: "Balance is too low!",
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
            childBuilder: () async {
              // Get invoice from LN Address
              final invoice = await getInvoiceFromLnaddressOrLnurl(
                amountMsats: amountMsats,
                lnaddressOrLnurl: widget.lightningAddressOrLnurl!,
              );

              // Get and show payment preview
              final preview = await paymentPreview(
                federationId: widget.fed.federationId,
                bolt11: invoice,
              );

              return PaymentPreviewWidget(
                fed: widget.fed,
                paymentPreview: preview,
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
              amount = await balance(federationId: widget.fed.federationId);
            }
            return EcashSend(fed: widget.fed, amountMsats: amount);
          },
        );
      } else if (widget.paymentType == PaymentType.onchain) {
        showAppModalBottomSheet(
          context: context,
          childBuilder: () async {
            return OnchainSend(
              fed: widget.fed,
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
            _displayedFiatInput = (_displayedFiatInput ?? '') + digit;
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

    return Center(
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
                    widget.fed.federationName,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Available',
                    style: TextStyle(fontSize: 11, color: Colors.grey),
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
          ],
        ),
      ),
    );
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
          title: const Text(
            'Enter Amount',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          centerTitle: true,
          backgroundColor: Colors.transparent,
          elevation: 0,
        ),
        body: Column(
          children: [
            _buildFederationCard(),
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
                                tooltip: 'Swap input currency',
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
                          : const Text(
                            'Confirm',
                            style: TextStyle(
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

                        _displayedFiatInput =
                            (_displayedFiatInput ?? '') + digit.toString();

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
