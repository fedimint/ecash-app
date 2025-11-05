import 'dart:async';
import 'constants/transaction_keys.dart';

import 'package:ecashapp/db.dart';
import 'package:ecashapp/detail_row.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/providers/preferences_provider.dart';
import 'package:ecashapp/success.dart';
import 'package:ecashapp/toast.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

class Request extends StatefulWidget {
  final String invoice;
  final OperationId operationId;
  final FederationSelector fed;
  final BigInt requestedAmountMsats;
  final BigInt totalMsats;
  final String gateway;
  final String pubkey;
  final String paymentHash;
  final BigInt expiry;

  const Request({
    super.key,
    required this.invoice,
    required this.operationId,
    required this.fed,
    required this.requestedAmountMsats,
    required this.totalMsats,
    required this.gateway,
    required this.pubkey,
    required this.paymentHash,
    required this.expiry,
  });

  @override
  State<Request> createState() => _RequestState();
}

class _RequestState extends State<Request> with SingleTickerProviderStateMixin {
  bool _copied = false;
  late Duration _remaining;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    AppLogger.instance.info("Invoice size: ${widget.invoice.length}");
    _remaining = Duration(seconds: widget.expiry.toInt());
    _startCountdown();
    _waitForPayment();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _startCountdown() {
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_remaining.inSeconds <= 0) {
        timer.cancel();
        return;
      }
      setState(() {
        _remaining -= const Duration(seconds: 1);
      });
    });
  }

  void _waitForPayment() async {
    try {
      await awaitReceive(
        federationId: widget.fed.federationId,
        operationId: widget.operationId,
      );
      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder:
                (context) => Success(
                  lightning: true,
                  received: true,
                  amountMsats: widget.requestedAmountMsats,
                ),
          ),
        );
        await Future.delayed(const Duration(seconds: 4));
      }
    } catch (e) {
      AppLogger.instance.error("Error occurred while receiving payment: $e");
      ToastService().show(
        message: "Could not receive payment",
        duration: const Duration(seconds: 5),
        onTap: () {},
        icon: Icon(Icons.error),
      );
    } finally {
      if (mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    }
  }

  void _copyInvoice() {
    Clipboard.setData(ClipboardData(text: widget.invoice));
    setState(() => _copied = true);
    ToastService().show(
      message: "Invoice copied to clipboard",
      duration: const Duration(seconds: 5),
      onTap: () {},
      icon: Icon(Icons.check),
    );
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  String _formatDuration(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');

    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:$minutes:$seconds';
    } else {
      return '$minutes:$seconds';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bitcoinDisplay = context.select<PreferencesProvider, BitcoinDisplay>((prefs) => prefs.bitcoinDisplay);
    final abbreviatedInvoice = getAbbreviatedText(widget.invoice);
    final fees = widget.totalMsats - widget.requestedAmountMsats;

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: theme.colorScheme.primary.withOpacity(0.5),
                  ),
                ),
                child: Text(
                  _formatDuration(_remaining),
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurface,
                    fontFeatures: [const FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Lightning Request',
            style: theme.textTheme.headlineSmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 24),
          AspectRatio(
            aspectRatio: 1,
            child: GestureDetector(
              onTap: () {
                showDialog(
                  context: context,
                  builder:
                      (_) => Dialog(
                        backgroundColor: Colors.transparent,
                        insetPadding: EdgeInsets.zero,
                        child: GestureDetector(
                          onTap:
                              () =>
                                  Navigator.of(
                                    context,
                                    rootNavigator: true,
                                  ).pop(),
                          child: Container(
                            width: double.infinity,
                            height: double.infinity,
                            color: Colors.black.withOpacity(0.9),
                            child: Center(
                              child: QrImageView(
                                data: widget.invoice,
                                version: QrVersions.auto,
                                backgroundColor: Colors.white,
                                size: MediaQuery.of(context).size.width * 0.9,
                              ),
                            ),
                          ),
                        ),
                      ),
                );
              },
              child: QrImageView(
                data: widget.invoice,
                version: QrVersions.auto,
                backgroundColor: Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: theme.colorScheme.primary.withOpacity(0.4),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    abbreviatedInvoice,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onSurface,
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  icon: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    transitionBuilder:
                        (child, anim) =>
                            ScaleTransition(scale: anim, child: child),
                    child:
                        _copied
                            ? Icon(
                              Icons.check,
                              key: const ValueKey('copied'),
                              color: theme.colorScheme.primary,
                            )
                            : Icon(
                              Icons.copy,
                              key: const ValueKey('copy'),
                              color: theme.colorScheme.primary,
                            ),
                  ),
                  onPressed: _copyInvoice,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainer,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: theme.colorScheme.primary.withOpacity(0.25),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CopyableDetailRow(
                  label: TransactionDetailKeys.amount,
                  value: formatBalance(widget.requestedAmountMsats, true, bitcoinDisplay),
                ),
                CopyableDetailRow(
                  label: TransactionDetailKeys.fees,
                  value: formatBalance(fees, true, bitcoinDisplay),
                ),
                CopyableDetailRow(
                  label: TransactionDetailKeys.gateway,
                  value: widget.gateway,
                ),
                CopyableDetailRow(
                  label: TransactionDetailKeys.payeePublicKey,
                  value: widget.pubkey,
                ),
                CopyableDetailRow(
                  label: TransactionDetailKeys.paymentHash,
                  value: widget.paymentHash,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
