import 'package:ecashapp/db.dart';
import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/providers/preferences_provider.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// A federation summary card showing the federation's image, name and balance.
///
/// When [onTap] is non-null the card is interactive and shows a chevron,
/// signalling that tapping it opens a federation picker. Shared by the amount
/// screen (`number_pad.dart`) and the LNURLw withdraw screen.
class FederationCard extends StatelessWidget {
  final FederationSelector federation;

  /// Federation logo URL (from `FederationMeta.picture`). Falls back to the
  /// bundled Fedimint icon when null/empty or when the image fails to load.
  final String? pictureUrl;

  /// Balance shown under the name. `null` renders a loading spinner.
  final BigInt? balanceMsats;

  /// When true the balance (and card accent) is rendered in red, e.g. when the
  /// amount being sent exceeds the available balance.
  final bool isOverBalance;

  /// Tap handler. When null the card is non-interactive and hides the chevron.
  final VoidCallback? onTap;

  final EdgeInsetsGeometry margin;

  const FederationCard({
    super.key,
    required this.federation,
    required this.pictureUrl,
    required this.balanceMsats,
    this.isOverBalance = false,
    this.onTap,
    this.margin = const EdgeInsets.fromLTRB(16, 16, 16, 12),
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bitcoinDisplay = context.select<PreferencesProvider, BitcoinDisplay>(
      (prefs) => prefs.bitcoinDisplay,
    );
    final hasPicture = pictureUrl != null && pictureUrl!.isNotEmpty;

    return Center(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          constraints: const BoxConstraints(maxWidth: 400),
          margin: margin,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color:
                  isOverBalance
                      ? Colors.red.withValues(alpha: 0.4)
                      : theme.colorScheme.primary.withValues(alpha: 0.1),
              width: 1,
            ),
            boxShadow: [
              if (isOverBalance)
                BoxShadow(
                  color: Colors.red.withValues(alpha: 0.2),
                  blurRadius: 12,
                  spreadRadius: 2,
                  offset: const Offset(0, 2),
                )
              else
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
            ],
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(28),
                child: SizedBox(
                  width: 56,
                  height: 56,
                  child:
                      hasPicture
                          ? Image.network(
                            pictureUrl!,
                            fit: BoxFit.cover,
                            errorBuilder:
                                (context, error, stackTrace) => Image.asset(
                                  'assets/images/fedimint-icon-color.png',
                                  fit: BoxFit.cover,
                                ),
                          )
                          : Image.asset(
                            'assets/images/fedimint-icon-color.png',
                            fit: BoxFit.cover,
                          ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      federation.federationName,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      context.l10n.available,
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                    const SizedBox(height: 2),
                    balanceMsats == null
                        ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.grey,
                          ),
                        )
                        : AnimatedDefaultTextStyle(
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeInOut,
                          style: TextStyle(
                            fontSize: 14,
                            color: isOverBalance ? Colors.red : Colors.grey,
                          ),
                          child: Text(
                            formatBalance(balanceMsats!, false, bitcoinDisplay),
                          ),
                        ),
                  ],
                ),
              ),
              if (onTap != null)
                Icon(Icons.unfold_more, color: Colors.grey[500], size: 20),
            ],
          ),
        ),
      ),
    );
  }
}
