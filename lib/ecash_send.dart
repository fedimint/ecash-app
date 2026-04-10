import 'dart:async';
import 'dart:convert';
import 'constants/transaction_keys.dart';
import 'package:ecashapp/db.dart';
import 'package:ecashapp/detail_row.dart';
import 'package:ecashapp/providers/preferences_provider.dart';
import 'package:ecashapp/fountain.dart';
import 'package:ecashapp/qr_export.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/toast.dart';
import 'package:ecashapp/utils.dart';
import 'package:ecashapp/utils/pin_guard.dart';
import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

enum _QrMode { legacy, fountain }

class EcashSend extends StatefulWidget {
  final FederationSelector fed;
  final BigInt amountMsats;

  const EcashSend({super.key, required this.fed, required this.amountMsats});

  @override
  State<EcashSend> createState() => _EcashSendState();
}

class _EcashSendState extends State<EcashSend> {
  OobNotesWrapper? _notes;
  Stream<String>? _fragmentStream;
  bool _loading = true;
  bool _copied = false;
  _QrMode _mode = _QrMode.legacy;

  @override
  void initState() {
    super.initState();
    _loadEcash();
  }

  Future<void> _loadEcash() async {
    try {
      final authorized = await checkSpendingPin(context);
      if (!authorized) {
        if (mounted) Navigator.of(context).pop();
        return;
      }
      final notes = await sendEcash(
        federationId: widget.fed.federationId,
        amountMsats: widget.amountMsats,
      );

      final encoder = OobNotesEncoder(notes: notes);
      final legacyFrames = dataToFrames(utf8.encode(notes.toString()));

      setState(() {
        _notes = notes;
        _fragmentStream = _createFrameStream(encoder, legacyFrames);
        _loading = false;
      });
    } catch (e) {
      AppLogger.instance.error("Could not send Ecash: $e");
      ToastService().show(
        message: context.l10n.couldNotSendEcash,
        duration: const Duration(seconds: 5),
        onTap: () {},
        icon: Icon(Icons.error),
      );
      setState(() {
        _notes = null;
        _loading = false;
      });
    }
  }

  Stream<String> _createFrameStream(
    OobNotesEncoder encoder,
    List<String> legacyFrames,
  ) async* {
    int legacyIndex = 0;
    while (true) {
      if (_mode == _QrMode.legacy && legacyFrames.isNotEmpty) {
        yield legacyFrames[legacyIndex % legacyFrames.length];
        legacyIndex++;
      } else {
        yield await encoder.nextFragment();
      }
      await Future.delayed(const Duration(milliseconds: 300));
    }
  }

  void _copyEcash() {
    if (_notes == null) return;
    Clipboard.setData(ClipboardData(text: _notes!.toString()));
    setState(() => _copied = true);
    ToastService().show(
      message: context.l10n.ecashCopiedToClipboard,
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
    final bitcoinDisplay = context.select<PreferencesProvider, BitcoinDisplay>(
      (prefs) => prefs.bitcoinDisplay,
    );

    if (_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              context.l10n.gettingChangeFromMint,
              style: const TextStyle(color: Colors.white70),
            ),
          ],
        ),
      );
    }

    if (_notes == null) {
      return Center(child: Text(context.l10n.failedToLoadEcash));
    }

    final abbreviatedEcash = getAbbreviatedText(_notes!.toString());

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.lock_outline, size: 48),
          const SizedBox(height: 12),
          Text(
            context.l10n.ecashWithdrawn,
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
                child: StreamBuilder<String>(
                  stream: _fragmentStream,
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    return QrImageView(
                      data: snapshot.data!,
                      version: QrVersions.auto,
                      backgroundColor: Colors.white,
                    );
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SegmentedButton<_QrMode>(
            segments: [
              ButtonSegment<_QrMode>(
                value: _QrMode.legacy,
                label: Text('Legacy'), // i18n-ignore
                icon: const Icon(Icons.qr_code),
              ),
              ButtonSegment<_QrMode>(
                value: _QrMode.fountain,
                label: Text('Optimized'), // i18n-ignore
                icon: const Icon(Icons.waves),
              ),
            ],
            selected: {_mode},
            onSelectionChanged: (selection) {
              setState(() => _mode = selection.first);
            },
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
                  value: formatBalance(
                    widget.amountMsats,
                    false,
                    bitcoinDisplay,
                  ),
                ),
                CopyableDetailRow(
                  label: context.l10n.federationLabel,
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
                    message: context.l10n.amountSpent(
                      formatBalance(widget.amountMsats, false, bitcoinDisplay),
                    ),
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
              child: Text(context.l10n.confirmPayment),
            ),
          ),
        ],
      ),
    );
  }
}
