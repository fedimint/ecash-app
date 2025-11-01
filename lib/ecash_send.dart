import 'dart:async';
import 'constants/transaction_keys.dart';
import 'dart:convert';
import 'package:ecashapp/detail_row.dart';
import 'package:ecashapp/providers/preferences_provider.dart';
import 'package:ecashapp/qr_export.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/toast.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

class EcashSend extends StatefulWidget {
  final FederationSelector fed;
  final BigInt amountMsats;

  const EcashSend({super.key, required this.fed, required this.amountMsats});

  @override
  State<EcashSend> createState() => _EcashSendState();
}

class _EcashSendState extends State<EcashSend> {
  String? _ecash;
  List<String> _qrChunks = [];
  bool _loading = true;
  bool _copied = false;

  int _currentChunkIndex = 0;
  Timer? _qrLoopTimer;

  @override
  void initState() {
    super.initState();
    _loadEcash();
  }

  @override
  void dispose() {
    _qrLoopTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadEcash() async {
    try {
      final ecash = await sendEcash(
        federationId: widget.fed.federationId,
        amountMsats: widget.amountMsats,
      );

      final ecashString = ecash.$2;
      final chunked = dataToFrames(utf8.encode(ecashString));

      setState(() {
        _ecash = ecashString;
        _qrChunks = chunked;
        _loading = false;
      });

      if (_qrChunks.length > 1) _startQrLoop();
    } catch (e) {
      AppLogger.instance.error("Could not send Ecash: $e");
      ToastService().show(
        message: "Could not send Ecash",
        duration: const Duration(seconds: 5),
        onTap: () {},
        icon: Icon(Icons.error),
      );
      setState(() {
        _ecash = null;
        _loading = false;
      });
    }
  }

  void _startQrLoop() {
    _qrLoopTimer = Timer.periodic(const Duration(milliseconds: 300), (_) {
      setState(() {
        _currentChunkIndex = (_currentChunkIndex + 1) % _qrChunks.length;
      });
    });
  }

  void _copyEcash() {
    if (_ecash == null) return;
    Clipboard.setData(ClipboardData(text: _ecash!));
    setState(() => _copied = true);
    ToastService().show(
      message: "Ecash copied to clipboard",
      duration: const Duration(seconds: 5),
      onTap: () {},
      icon: Icon(Icons.check),
    );
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bitcoinDisplay = context.watch<PreferencesProvider>().bitcoinDisplay;

    if (_loading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text(
              "Getting change from mint...",
              style: TextStyle(color: Colors.white70),
            ),
          ],
        ),
      );
    }

    if (_ecash == null) {
      return const Center(child: Text("⚠️ Failed to load Ecash"));
    }

    final abbreviatedEcash = getAbbreviatedText(_ecash!);

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.lock_outline, size: 48),
          const SizedBox(height: 12),
          Text(
            'Ecash Withdrawn',
            style: theme.textTheme.headlineSmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 24),
          Stack(
            alignment: Alignment.topRight,
            children: [
              AspectRatio(
                aspectRatio: 1,
                child: QrImageView(
                  data: _qrChunks[_currentChunkIndex],
                  version: QrVersions.auto,
                  backgroundColor: Colors.white,
                ),
              ),
            ],
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
                    abbreviatedEcash,
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
                  onPressed: _copyEcash,
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
                  value: formatBalance(widget.amountMsats, false, bitcoinDisplay),
                ),
                CopyableDetailRow(
                  label: 'Federation',
                  value: widget.fed.federationName,
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () {
                if (mounted) {
                  Navigator.of(context).popUntil((route) => route.isFirst);
                  ToastService().show(
                    message:
                        '${formatBalance(widget.amountMsats, false, bitcoinDisplay)} spent',
                    duration: const Duration(seconds: 5),
                    onTap: () {},
                    icon: Icon(Icons.currency_bitcoin),
                  );
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: theme.colorScheme.primary,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text("Confirm Payment"),
            ),
          ),
        ],
      ),
    );
  }
}
