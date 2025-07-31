import 'package:carbine/lib.dart';
import 'package:carbine/multimint.dart';
import 'package:carbine/success.dart';
import 'package:carbine/toast.dart';
import 'package:carbine/utils.dart';
import 'package:flutter/material.dart';

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

    try {
      final operationId = await reissueEcash(
        federationId: widget.fed.federationId,
        ecash: widget.ecash,
      );
      await awaitEcashReissue(
        federationId: widget.fed.federationId,
        operationId: operationId,
      );

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
      Navigator.of(context).popUntil((route) => route.isFirst);
    } catch (e) {
      AppLogger.instance.error("Could not reissue ecash $e");
      ToastService().show(
        message: "Could not claim ecash",
        duration: const Duration(seconds: 5),
        onTap: () {},
        icon: Icon(Icons.error),
      );
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  Future<void> _handleAsyncRedeem() async {
    try {
      await reissueEcash(
        federationId: widget.fed.federationId,
        ecash: widget.ecash,
      );
    } catch (e) {
      AppLogger.instance.error("Could not reissue ecash $e");
      ToastService().show(
        message: "Could not claim ecash",
        duration: const Duration(seconds: 5),
        onTap: () {},
        icon: Icon(Icons.error),
      );
    }

    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Do you want to redeem the following ecash to ${widget.fed.federationName}?',
          style: theme.textTheme.titleLarge,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        Text(
          formatBalance(widget.amount, false),
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
