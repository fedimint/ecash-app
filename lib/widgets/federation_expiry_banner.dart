import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/screens/federation_expiry_screen.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Height [FederationExpiryBanner] lays out at, for the pinned sliver header
/// that has to declare its extent before the banner is measured.
///
/// Declaring less than the banner measures clips it; declaring more trips the
/// sliver's layoutExtent-vs-paintExtent assertion unless the header forces its
/// child to fill the box. Both texts are capped at one line, so only they grow
/// with the user's font setting and the padding around them stays fixed —
/// which is why the scale applies to just one of the two terms.
///
/// `federation_expiry_banner_test.dart` pins this to what the widget actually
/// measures, so a padding or text-style change there fails a test rather than
/// an assertion on someone's dashboard.
double federationExpiryBannerExtent(BuildContext context) {
  const chrome = 32.0; // 8 outer top padding + 12/12 card vertical padding
  const textLines = 40.0; // title + gap + subtitle, at scale 1.0
  return chrome + MediaQuery.textScalerOf(context).scale(textLines);
}

/// Loud, tappable warning that the guardians have scheduled this federation's
/// shutdown.
///
/// Sits directly under the balance on the dashboard, in the error colour, and
/// stays put while the transaction list scrolls — the point is that it cannot
/// be missed by someone who only ever glances at their balance.
class FederationExpiryBanner extends StatelessWidget {
  /// Unix seconds the guardians published as the shutdown time.
  final BigInt expiryTimestamp;
  final VoidCallback onTap;

  const FederationExpiryBanner({
    super.key,
    required this.expiryTimestamp,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final warning = theme.colorScheme.error;
    final expiry = expiryDateTime(expiryTimestamp);
    final date = DateFormat.yMMMd().format(expiry);
    final subtitle =
        expiry.isBefore(DateTime.now())
            ? context.l10n.federationExpiryBannerSubtitlePast(date)
            : context.l10n.federationExpiryBannerSubtitle(date);

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Material(
        color: warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: warning.withValues(alpha: 0.5)),
            ),
            child: Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: warning, size: 24),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        context.l10n.federationExpiryBannerTitle,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: warning,
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.white70,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: warning, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
