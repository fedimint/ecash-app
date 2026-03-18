import 'package:ecashapp/db.dart';
import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/providers/preferences_provider.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class DashboardBalance extends StatelessWidget {
  final BigInt? balanceMsats;
  final bool isLoading;
  final bool recovering;
  final bool showMsats;
  final VoidCallback onToggle;
  final Map<FiatCurrency, double> btcPrices;
  final bool isLoadingPrices;
  final bool pricesFailed;

  const DashboardBalance({
    super.key,
    required this.balanceMsats,
    required this.isLoading,
    required this.recovering,
    required this.showMsats,
    required this.onToggle,
    required this.btcPrices,
    required this.isLoadingPrices,
    required this.pricesFailed,
  });

  @override
  Widget build(BuildContext context) {
    BigInt sats =
        balanceMsats != null ? balanceMsats! ~/ BigInt.from(1000) : BigInt.zero;
    final fiatCurrency = context.select<PreferencesProvider, FiatCurrency>(
      (prefs) => prefs.fiatCurrency,
    );
    final fiatText = calculateFiatValue(
      btcPrices[fiatCurrency],
      sats.toInt(),
      fiatCurrency,
    );
    if (recovering) {
      return const SizedBox.shrink();
    } else if (isLoading) {
      return const Center(child: CircularProgressIndicator());
    } else {
      return Center(
        child: GestureDetector(
          onTap: onToggle,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                formatBalance(
                  balanceMsats,
                  showMsats,
                  context.select<PreferencesProvider, BitcoinDisplay>(
                    (prefs) => prefs.bitcoinDisplay,
                  ),
                ),
                style: Theme.of(context).textTheme.displayLarge?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              if (isLoadingPrices)
                Text(
                  context.l10n.loadingPrices,
                  style: const TextStyle(fontSize: 16, color: Colors.grey),
                  textAlign: TextAlign.center,
                )
              else if (pricesFailed)
                Text(
                  context.l10n.priceUnavailable,
                  style: const TextStyle(fontSize: 16, color: Colors.grey),
                  textAlign: TextAlign.center,
                )
              else if (btcPrices.isNotEmpty)
                Text(
                  fiatText,
                  style: const TextStyle(fontSize: 24, color: Colors.grey),
                  textAlign: TextAlign.center,
                ),
            ],
          ),
        ),
      );
    }
  }
}
