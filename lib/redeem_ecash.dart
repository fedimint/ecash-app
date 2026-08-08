import 'package:ecashapp/db.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/providers/preferences_provider.dart';
import 'package:ecashapp/success.dart';
import 'package:ecashapp/toast.dart';
import 'package:ecashapp/utils.dart';
import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class EcashRedeemPrompt extends StatefulWidget {
  final FederationSelector fed;
  final String ecash;
  final BigInt amount;

  const EcashRedeemPrompt({
    super.key,
    required this.fed,
    required this.ecash,
    required this.amount,
  });

  @override
  State<EcashRedeemPrompt> createState() => _EcashRedeemPromptState();
}

class _EcashRedeemPromptState extends State<EcashRedeemPrompt> {
  bool _isLoading = false;
  ReissueFees? _fees;
  BigInt? _totalFeeMsats;
  BigInt? _inputFeeMsats;
  BigInt? _outputFeeMsats;
  BigInt? _dustMsats;
  bool _showFeeDetails = false;

  /// The fee quote could not be produced.
  ///
  /// Worth surfacing rather than shrugging off, because the quote is computed
  /// locally and needs the same things the reissue does — the federation client,
  /// a decodable token, a mint module. `reissue_ecash` then validates the notes
  /// on top of that. So a failed quote is not a missing cosmetic detail; it says
  /// this token cannot be redeemed here, and it says so before the user commits
  /// rather than after, with a specific reason instead of "could not claim".
  bool _feeQuoteFailed = false;

  @override
  void initState() {
    super.initState();
    _loadFees();
  }

  Future<void> _loadFees() async {
    try {
      final fees = await calculateEcashReissueFees(
        federationId: widget.fed.federationId,
        ecash: widget.ecash,
      );
      if (mounted) {
        setState(() {
          _fees = fees;
          _totalFeeMsats = fees.totalMsats;
          _inputFeeMsats = fees.inputMsats;
          _outputFeeMsats = fees.outputMsats;
          _dustMsats = fees.dustMsats;
        });
      }
    } catch (e) {
      AppLogger.instance.error("Could not calculate reissue fees: $e");
      if (mounted) {
        setState(() {
          _feeQuoteFailed = true;
        });
      }
    }
  }

  Future<void> _handleRedeem() async {
    // Both buttons are disabled without a quote, so this is a belt-and-braces
    // guard rather than a live path — but it removes the null-force that used to
    // throw a TypeError and surface as a generic "could not claim".
    final fees = _fees;
    if (fees == null) return;

    setState(() {
      _isLoading = true;
    });

    final l10n = context.l10n;
    final failureMessage = l10n.couldNotClaimEcash;

    try {
      final isSpent = await checkEcashSpent(
        federationId: widget.fed.federationId,
        ecash: widget.ecash,
      );

      if (isSpent) {
        if (mounted) {
          ToastService().show(
            message: l10n.ecashAlreadyClaimed,
            duration: const Duration(seconds: 5),
            onTap: () {},
            icon: Icon(Icons.error),
          );
          Navigator.of(context).pop();
          setState(() {
            _isLoading = false;
          });
        }
        return;
      }

      final operationId = await reissueEcash(
        federationId: widget.fed.federationId,
        ecash: widget.ecash,
        fees: fees,
      );

      // Past this point the reissue is submitted and persisted against
      // `operationId`, and the mint module will carry it to completion whether
      // or not this screen is still watching. A failure to *observe* the
      // outcome is therefore not a failure to redeem.
      final (bool, BigInt?) result;
      try {
        result = await awaitEcashReissue(
          federationId: widget.fed.federationId,
          operationId: operationId,
        );
      } catch (e) {
        AppLogger.instance.warn(
          "Reissue submitted but could not be observed: $e",
        );
        if (mounted) {
          ToastService().show(
            message: l10n.ecashRedeemStarted,
            duration: const Duration(seconds: 3),
            onTap: () {},
            icon: Icon(Icons.check),
          );
          Navigator.of(context).pop();
        }
        return;
      }

      // Judge the outcome on the reported result, not on whether an amount came
      // back. The amount is null for reasons unrelated to failure — an internal
      // reissue, or meta this build cannot read — so testing it reported
      // completed reissues as failures.
      if (!result.$1) {
        if (mounted) {
          ToastService().show(
            message: failureMessage,
            duration: const Duration(seconds: 5),
            onTap: () {},
            icon: Icon(Icons.error),
          );
          Navigator.of(context).pop();
          setState(() {
            _isLoading = false;
          });
        }
        return;
      }

      if (!mounted) return;

      Navigator.push(
        context,
        MaterialPageRoute(
          builder:
              (context) => Success(
                lightning: false,
                received: true,
                amountMsats: widget.amount,
              ),
        ),
      );
      await Future.delayed(const Duration(seconds: 4));
      if (mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    } catch (e) {
      AppLogger.instance.error("Could not reissue Ecash $e");
      if (mounted) {
        ToastService().show(
          message: failureMessage,
          duration: const Duration(seconds: 5),
          onTap: () {},
          icon: Icon(Icons.error),
        );
        Navigator.of(context).pop();
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _handleAsyncRedeem() async {
    final fees = _fees;
    if (fees == null) return;

    final l10n = context.l10n;
    try {
      final isSpent = await checkEcashSpent(
        federationId: widget.fed.federationId,
        ecash: widget.ecash,
      );

      if (isSpent) {
        ToastService().show(
          message: l10n.ecashAlreadyClaimed,
          duration: const Duration(seconds: 5),
          onTap: () {},
          icon: Icon(Icons.error),
        );
        return;
      }

      await reissueEcash(
        federationId: widget.fed.federationId,
        ecash: widget.ecash,
        fees: fees,
      );

      if (!mounted) return;

      Navigator.of(context).popUntil((route) => route.isFirst);
      ToastService().show(
        message: l10n.ecashRedeemStarted,
        duration: const Duration(seconds: 3),
        onTap: () {},
        icon: Icon(Icons.check),
      );
    } catch (e) {
      AppLogger.instance.error("Could not reissue Ecash $e");
      ToastService().show(
        message: l10n.couldNotClaimEcash,
        duration: const Duration(seconds: 5),
        onTap: () {},
        icon: Icon(Icons.error),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bitcoinDisplay = context.select<PreferencesProvider, BitcoinDisplay>(
      (prefs) => prefs.bitcoinDisplay,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          context.l10n.redeemEcashPrompt(widget.fed.federationName),
          style: theme.textTheme.titleLarge,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        Text(
          formatBalance(widget.amount, false, bitcoinDisplay),
          textAlign: TextAlign.center,
          style: theme.textTheme.displaySmall?.copyWith(
            fontWeight: FontWeight.bold,
            fontSize: 32,
            color: Theme.of(context).colorScheme.primary,
            letterSpacing: 1.5,
            shadows: [
              Shadow(
                blurRadius: 8,
                color: Theme.of(context).colorScheme.primary.withOpacity(0.4),
                offset: const Offset(0, 0),
              ),
            ],
          ),
        ),
        if (_totalFeeMsats != null && _totalFeeMsats! > BigInt.zero) ...[
          const SizedBox(height: 12),
          Text(
            context.l10n.redeemFee(
              formatBalance(_totalFeeMsats!, true, bitcoinDisplay),
            ),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurface.withOpacity(0.6),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            context.l10n.redeemYouReceive(
              formatBalance(
                widget.amount - _totalFeeMsats!,
                true,
                bitcoinDisplay,
              ),
            ),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurface.withOpacity(0.6),
            ),
          ),
        ],
        if (_feeQuoteFailed) ...[
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainer,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: theme.colorScheme.error),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.error_outline,
                      color: theme.colorScheme.error,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        context.l10n.redeemUnavailable,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  context.l10n.redeemUnavailableDetail,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 32),
        ElevatedButton(
          onPressed: (_isLoading || _fees == null) ? null : _handleRedeem,
          style: ElevatedButton.styleFrom(
            backgroundColor: theme.colorScheme.primary,
            foregroundColor: Colors.black,
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child:
              _isLoading
                  ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.black),
                    ),
                  )
                  : Text(context.l10n.redeemNow),
        ),
        const SizedBox(height: 16),
        OutlinedButton(
          onPressed: (_isLoading || _fees == null) ? null : _handleAsyncRedeem,
          style: OutlinedButton.styleFrom(
            foregroundColor: theme.colorScheme.primary,
            side: BorderSide(color: theme.colorScheme.primary),
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: Text(context.l10n.redeemWhenOnline),
        ),
        if (_totalFeeMsats != null && _totalFeeMsats! > BigInt.zero) ...[
          const SizedBox(height: 20),
          GestureDetector(
            onTap: () => setState(() => _showFeeDetails = !_showFeeDetails),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  context.l10n.redeemFeeDetails,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurface.withOpacity(0.5),
                  ),
                ),
                Icon(
                  _showFeeDetails ? Icons.expand_less : Icons.expand_more,
                  size: 20,
                  color: theme.colorScheme.onSurface.withOpacity(0.5),
                ),
              ],
            ),
          ),
          if (_showFeeDetails) ...[
            const SizedBox(height: 8),
            Text(
              context.l10n.redeemInputFee('${_inputFeeMsats!} msats'),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withOpacity(0.5),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              context.l10n.redeemOutputFee('${_outputFeeMsats!} msats'),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withOpacity(0.5),
              ),
            ),
            if (_dustMsats != null && _dustMsats! > BigInt.zero) ...[
              const SizedBox(height: 4),
              Text(
                context.l10n.redeemDustLoss('${_dustMsats!} msats'),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface.withOpacity(0.5),
                ),
              ),
            ],
          ],
        ],
      ],
    );
  }
}
