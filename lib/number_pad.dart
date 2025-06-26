import 'package:carbine/app.dart';
import 'package:carbine/ecash_send.dart';
import 'package:carbine/lib.dart';
import 'package:carbine/multimint.dart';
import 'package:carbine/onchain_send.dart';
import 'package:carbine/request.dart';
import 'package:carbine/theme.dart';
import 'package:carbine/utils.dart';
import 'package:carbine/models.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:numpad_layout/widgets/numpad.dart';
import 'package:flutter/services.dart';

enum WithdrawalMode { specificAmount, maxBalance }

class NumberPad extends StatefulWidget {
  final FederationSelector fed;
  final PaymentType paymentType;
  final double? btcPrice;
  final VoidCallback? onWithdrawCompleted;
  const NumberPad({
    super.key,
    required this.fed,
    required this.paymentType,
    required this.btcPrice,
    this.onWithdrawCompleted,
  });

  @override
  State<NumberPad> createState() => _NumberPadState();
}

class _NumberPadState extends State<NumberPad> {
  final FocusNode _numpadFocus = FocusNode();

  String _rawAmount = '';
  bool _creating = false;
  bool _loadingMax = false;
  WithdrawalMode _withdrawalMode = WithdrawalMode.specificAmount;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _numpadFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _numpadFocus.dispose();
    super.dispose();
  }

  String _formatAmount(String value) {
    if (value.isEmpty) return '₿0';
    final number = int.tryParse(value) ?? 0;
    final formatter = NumberFormat('₿#,###', 'en_US');
    return formatter.format(number).replaceAll(',', ' ');
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Failed to get balance')));
    } finally {
      setState(() => _loadingMax = false);
    }
  }

  Future<void> _onConfirm() async {
    setState(() => _creating = true);
    final amountSats = BigInt.tryParse(_rawAmount);
    if (amountSats != null) {
      if (widget.paymentType == PaymentType.lightning) {
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
        await showCarbineModalBottomSheet(
          context: context,
          child: Request(
            invoice: invoice.$1,
            fed: widget.fed,
            operationId: invoice.$2,
            requestedAmountMsats: requestedAmountMsats,
            totalMsats: contractAmount,
            gateway: gateway.$1,
            pubkey: invoice.$3,
            paymentHash: invoice.$4,
            expiry: invoice.$5,
          ),
        );
        invoicePaidToastVisible.value = true;
      } else if (widget.paymentType == PaymentType.ecash) {
        BigInt amount = amountSats * BigInt.from(1000);
        if (_withdrawalMode == WithdrawalMode.maxBalance) {
          amount = await balance(federationId: widget.fed.federationId);
        }
        showCarbineModalBottomSheet(
          context: context,
          child: EcashSend(fed: widget.fed, amountMsats: amount),
        );
      } else if (widget.paymentType == PaymentType.onchain) {
        showCarbineModalBottomSheet(
          context: context,
          child: OnchainSend(
            fed: widget.fed,
            amountSats: amountSats,
            withdrawalMode: _withdrawalMode,
            onWithdrawCompleted: widget.onWithdrawCompleted,
          ),
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
          if (_rawAmount.isNotEmpty) {
            _rawAmount = _rawAmount.substring(0, _rawAmount.length - 1);
            _withdrawalMode = WithdrawalMode.specificAmount;
          }
        });
      }
      if (digit != '') {
        setState(() {
          _rawAmount += digit;
          _withdrawalMode = WithdrawalMode.specificAmount;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final usdText = calculateUsdValue(
      widget.btcPrice,
      int.tryParse(_rawAmount) ?? 0,
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
            const SizedBox(height: 24),
            RichText(
              text: TextSpan(
                style: const TextStyle(color: Colors.white),
                children: [
                  TextSpan(
                    text: _formatAmount(_rawAmount),
                    style: const TextStyle(
                      fontSize: 48,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              usdText,
              style: const TextStyle(fontSize: 24, color: Colors.grey),
            ),
            const SizedBox(height: 24),
            Expanded(
              child: KeyboardListener(
                focusNode: _numpadFocus,
                onKeyEvent: _handleKeyEvent,
                child: Center(
                  child: NumPad(
                    arabicDigits: false,
                    onType: (value) {
                      setState(() {
                        _rawAmount += value.toString();
                        _withdrawalMode = WithdrawalMode.specificAmount;
                      });
                    },
                    numberStyle: const TextStyle(
                      fontSize: 24,
                      color: Colors.grey,
                    ),
                    leftWidget:
                        widget.paymentType == PaymentType.onchain ||
                                widget.paymentType == PaymentType.ecash
                            ? TextButton(
                              onPressed: _loadingMax ? null : _onMaxPressed,
                              style: TextButton.styleFrom(
                                minimumSize: const Size(50, 40),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 2,
                                ),
                              ),
                              child:
                                  _loadingMax
                                      ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.grey,
                                        ),
                                      )
                                      : const Text(
                                        'MAX',
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.bold,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.clip,
                                      ),
                            )
                            : null,
                    rightWidget: IconButton(
                      onPressed: () {
                        setState(() {
                          if (_rawAmount.isNotEmpty) {
                            _rawAmount = _rawAmount.substring(
                              0,
                              _rawAmount.length - 1,
                            );
                            _withdrawalMode = WithdrawalMode.specificAmount;
                          }
                        });
                      },
                      icon: const Icon(Icons.backspace),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _onConfirm,
                  child:
                      _creating
                          ? const CircularProgressIndicator(color: Colors.white)
                          : const Text(
                            'Confirm',
                            style: TextStyle(fontSize: 20),
                          ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
