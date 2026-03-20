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
    }
  }

  Future<void> _handleRedeem() async {
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
        fees: _fees!,
      );

      final result = await awaitEcashReissue(
        federationId: widget.fed.federationId,
        operationId: operationId,
      );

      if (result.$2 == null || result.$2 == BigInt.zero) {
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
        fees: _fees!,
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
            'Fee: ${formatBalance(_totalFeeMsats!, true, bitcoinDisplay)}',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurface.withOpacity(0.6),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'You receive: ${formatBalance(widget.amount - _totalFeeMsats!, true, bitcoinDisplay)}',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurface.withOpacity(0.6),
            ),
          ),
        ],
        const SizedBox(height: 32),
        ElevatedButton(
          onPressed: _isLoading ? null : _handleRedeem,
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
          onPressed: _isLoading ? null : _handleAsyncRedeem,
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
                  'Fee Details',
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
              'Input fee: ${_inputFeeMsats!} msats',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withOpacity(0.5),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Output fee: ${_outputFeeMsats!} msats',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withOpacity(0.5),
              ),
            ),
            if (_dustMsats != null && _dustMsats! > BigInt.zero) ...[
              const SizedBox(height: 4),
              Text(
                'Dust loss: ${_dustMsats!} msats',
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
