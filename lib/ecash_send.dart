import 'dart:async';
import 'dart:convert';
import 'constants/transaction_keys.dart';
import 'package:ecashapp/db.dart';
import 'package:ecashapp/detail_row.dart';
import 'package:ecashapp/error_helper.dart';
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
  // Quoting the (display-only) send fee, before anything is spent.
  bool _quoting = true;
  // The quote: the actual amount that will be spent (the requested amount
  // rounded up to a representable denomination) plus the federation fee. Null
  // if the quote was unavailable (it's display-only, so that doesn't block the
  // send).
  EcashSendFees? _fees;
  // Generating the ecash — this is the step that actually spends.
  bool _generating = false;
  bool _copied = false;
  _QrMode _mode = _QrMode.legacy;

  @override
  void initState() {
    super.initState();
    _loadQuote();
  }

  /// Quotes the send fee without spending, so the user can review the cost
  /// before committing. The quote is display-only: if it fails we still let the
  /// user proceed, just without a fee figure.
  Future<void> _loadQuote() async {
    try {
      final fees = await calculateEcashSendFees(
        federationId: widget.fed.federationId,
        amountMsats: widget.amountMsats,
      );
      if (!mounted) return;
      setState(() {
        _fees = fees;
        _quoting = false;
      });
    } catch (e) {
      AppLogger.instance.warn("Could not quote Ecash send fee: $e");
      if (!mounted) return;
      setState(() {
        _fees = null;
        _quoting = false;
      });
    }
  }

  /// Actually performs the send: this is where the ecash is taken from the
  /// wallet. Only invoked once the user confirms on the review screen.
  Future<void> _generateEcash() async {
    final authorized = await checkSpendingPin(context);
    if (!authorized) return;
    setState(() => _generating = true);
    try {
      final notes = await sendEcash(
        federationId: widget.fed.federationId,
        amountMsats: widget.amountMsats,
        // Persist the quoted fee so it can be shown in the transaction details.
        // Falls back to zero if the (display-only) quote was unavailable.
        feeMsats: _fees?.feeMsats ?? BigInt.zero,
      );

      final encoder = OobNotesEncoder(notes: notes);
      final legacyFrames = dataToFrames(utf8.encode(notes.toString()));

      if (!mounted) return;
      setState(() {
        _notes = notes;
        _fragmentStream = _createFrameStream(encoder, legacyFrames);
        _generating = false;
      });
    } catch (e) {
      AppLogger.instance.error("Could not send Ecash: $e");
      if (mounted) showErrorToast(context, e);
      if (!mounted) return;
      setState(() => _generating = false);
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

  Widget _buildLoading(String message) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(message, style: const TextStyle(color: Colors.white70)),
        ],
      ),
    );
  }

  /// Review screen shown before spending: the amount, the quoted federation
  /// fee (when available) and the resulting total, with a button that performs
  /// the actual send.
  Widget _buildReview(
    ThemeData theme,
    BitcoinDisplay bitcoinDisplay,
    bool showMsats,
  ) {
    final fees = _fees;
    // The amount the send will actually spend: the requested amount rounded up
    // to a representable denomination. Falls back to the requested amount if the
    // quote was unavailable.
    final amount = fees?.amountMsats ?? widget.amountMsats;
    final feeMsats = fees?.feeMsats;
    final total = fees == null ? null : fees.amountMsats + fees.feeMsats;

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.currency_bitcoin, size: 48),
          const SizedBox(height: 12),
          Text(
            context.l10n.reviewEcashSend,
            style: theme.textTheme.headlineSmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 24),
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
                  value: formatBalance(amount, showMsats, bitcoinDisplay),
                ),
                if (feeMsats != null)
                  CopyableDetailRow(
                    label: TransactionDetailKeys.federationFee,
                    value: formatBalance(feeMsats, showMsats, bitcoinDisplay),
                  ),
                if (total != null)
                  CopyableDetailRow(
                    label: TransactionDetailKeys.total,
                    value: formatBalance(total, showMsats, bitcoinDisplay),
                  ),
                CopyableDetailRow(
                  label: context.l10n.federationLabel,
                  value: widget.fed.federationName,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              icon: const Icon(Icons.send, color: Colors.black),
              label: Text(context.l10n.confirmAndSendEcash),
              onPressed: _generateEcash,
              style: ElevatedButton.styleFrom(
                backgroundColor: theme.colorScheme.primary,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bitcoinDisplay = context.select<PreferencesProvider, BitcoinDisplay>(
      (prefs) => prefs.bitcoinDisplay,
    );
    final showMsats = context.select<PreferencesProvider, bool>(
      (prefs) => prefs.showMsats,
    );

    if (_quoting) {
      return _buildLoading(context.l10n.calculatingFees);
    }

    if (_generating) {
      return _buildLoading(context.l10n.gettingChangeFromMint);
    }

    // Not spent yet: show the review screen with the quoted fee. The send only
    // happens when the user confirms.
    if (_notes == null) {
      return _buildReview(theme, bitcoinDisplay, showMsats);
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
                  // The actual amount of the generated ecash (the requested
                  // amount rounded up to representable denominations), not the
                  // raw requested value.
                  value: formatBalance(
                    _notes!.amountMsats(),
                    showMsats,
                    bitcoinDisplay,
                  ),
                ),
                // Show the federation fee and total spent only when a fee was
                // actually paid (exact-change sends are free), matching the
                // review screen and the transaction details.
                if (_fees != null && _fees!.feeMsats > BigInt.zero) ...[
                  CopyableDetailRow(
                    label: TransactionDetailKeys.federationFee,
                    value: formatBalance(
                      _fees!.feeMsats,
                      showMsats,
                      bitcoinDisplay,
                    ),
                  ),
                  CopyableDetailRow(
                    label: TransactionDetailKeys.total,
                    value: formatBalance(
                      _notes!.amountMsats() + _fees!.feeMsats,
                      showMsats,
                      bitcoinDisplay,
                    ),
                  ),
                ],
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
                      formatBalance(
                        _notes!.amountMsats(),
                        showMsats,
                        bitcoinDisplay,
                      ),
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
