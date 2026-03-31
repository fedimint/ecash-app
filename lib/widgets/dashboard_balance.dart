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
  final Map<FiatCurrency, double> btcPrices;
  final bool isLoadingPrices;
  final bool pricesFailed;
  final LightningAddressConfig? lnAddressConfig;
  final VoidCallback? onLnAddressTap;
  final VoidCallback? onWalletTap;

  const DashboardBalance({
    super.key,
    required this.balanceMsats,
    required this.isLoading,
    required this.recovering,
    required this.btcPrices,
    required this.isLoadingPrices,
    required this.pricesFailed,
    this.lnAddressConfig,
    this.onLnAddressTap,
    this.onWalletTap,
  });

  @override
  Widget build(BuildContext context) {
    BigInt sats =
        balanceMsats != null ? balanceMsats! ~/ BigInt.from(1000) : BigInt.zero;
    final fiatCurrency = context.select<PreferencesProvider, FiatCurrency>(
      (prefs) => prefs.fiatCurrency,
    );
    final showMsats = context.select<PreferencesProvider, bool>(
      (prefs) => prefs.showMsats,
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
          onTap: onWalletTap,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (onWalletTap != null) const SizedBox(width: 32),
                  Flexible(
                    child: Text(
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
                        fontSize: 48,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  if (onWalletTap != null)
                    Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(
                        Icons.chevron_right,
                        color: Theme.of(context).colorScheme.primary,
                        size: 28,
                      ),
                    ),
                ],
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
                  style: const TextStyle(fontSize: 28, color: Colors.grey),
                  textAlign: TextAlign.center,
                ),
              if (lnAddressConfig != null) ...[
                const SizedBox(height: 10),
                GestureDetector(
                  onTap: onLnAddressTap,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.flash_on,
                          color: Colors.amber,
                          size: 16,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '${lnAddressConfig!.username}@${lnAddressConfig!.domain}',
                          style: Theme.of(
                            context,
                          ).textTheme.bodyMedium?.copyWith(color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    }
  }
}
