import 'package:flutter/material.dart';
import 'package:carbine/utils.dart';

class DashboardBalance extends StatelessWidget {
  final BigInt? balanceMsats;
  final bool isLoading;
  final bool recovering;
  final bool showMsats;
  final VoidCallback onToggle;
  final double? btcPrice;

  const DashboardBalance({
    super.key,
    required this.balanceMsats,
    required this.isLoading,
    required this.recovering,
    required this.showMsats,
    required this.onToggle,
    required this.btcPrice,
  });

  @override
  Widget build(BuildContext context) {
    BigInt sats = balanceMsats != null ? balanceMsats! ~/ BigInt.from(1000) : BigInt.zero;
    final usdText = calculateUsdValue(btcPrice, sats.toInt());
    if (recovering) {
      return Center(
        child: Text(
          "Recovering...",
          style: Theme.of(context).textTheme.displaySmall?.copyWith(
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.bold,
          ),
          textAlign: TextAlign.center,
        ),
      );
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
                formatBalance(balanceMsats, showMsats),
                style: Theme.of(context).textTheme.displayLarge?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              if (btcPrice != null)
                Text(
                  usdText,
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
