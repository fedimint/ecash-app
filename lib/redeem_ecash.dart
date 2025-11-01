import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/providers/preferences_provider.dart';
import 'package:ecashapp/success.dart';
import 'package:ecashapp/toast.dart';
import 'package:ecashapp/utils.dart';
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

  Future<void> _handleRedeem() async {
    setState(() {
      _isLoading = true;
    });

    final failureMessage = "Could not claim Ecash";

    try {
      final isSpent = await checkEcashSpent(
        federationId: widget.fed.federationId,
        ecash: widget.ecash,
      );

      if (isSpent) {
        if (mounted) {
          ToastService().show(
            message: "This Ecash has already been claimed",
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
    try {
      final isSpent = await checkEcashSpent(
        federationId: widget.fed.federationId,
        ecash: widget.ecash,
      );

      if (isSpent) {
        ToastService().show(
          message: "This Ecash has already been claimed",
          duration: const Duration(seconds: 5),
          onTap: () {},
          icon: Icon(Icons.error),
        );
        return;
      }

      await reissueEcash(
        federationId: widget.fed.federationId,
        ecash: widget.ecash,
      );

      if (!mounted) return;

      Navigator.of(context).popUntil((route) => route.isFirst);
      ToastService().show(
        message: "Ecash redeem started in background",
        duration: const Duration(seconds: 3),
        onTap: () {},
        icon: Icon(Icons.check),
      );
    } catch (e) {
      AppLogger.instance.error("Could not reissue Ecash $e");
      ToastService().show(
        message: "Could not claim Ecash",
        duration: const Duration(seconds: 5),
        onTap: () {},
        icon: Icon(Icons.error),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bitcoinDisplay = context.watch<PreferencesProvider>().bitcoinDisplay;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Do you want to redeem the following Ecash to ${widget.fed.federationName}?',
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
                  : const Text('Redeem now'),
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
          child: const Text('Redeem when online'),
        ),
      ],
    );
  }
}
