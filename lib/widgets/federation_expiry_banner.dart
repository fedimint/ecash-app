import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/screens/federation_expiry_screen.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;

/// Height [FederationExpiryBanner] lays out at, for the pinned sliver header
/// that has to declare its extent before the banner is measured.
///
/// The banner sizes itself to exactly this value, so the header and the widget
/// can never disagree. The two text lines are measured with the styles and
/// font scale the banner renders with (the engine rounds line heights to whole
/// pixels, so a linear formula would drift), leaving only the fixed padding
/// around them as an assumption. `federation_expiry_banner_test.dart` renders
/// the banner at several font scales and fails if that assumption stops
/// holding, so a padding change here breaks a test rather than clipping on
/// someone's dashboard.
double federationExpiryBannerExtent(BuildContext context) {
  // 8 outer top padding + 12/12 card padding + 1/1 border + 2 gap between lines.
  const chrome = 36.0;
  final textTheme = Theme.of(context).textTheme;
  return chrome +
      _lineHeight(context, _titleStyle(textTheme)) +
      _lineHeight(context, _subtitleStyle(textTheme));
}

TextStyle? _titleStyle(TextTheme textTheme) =>
    textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold);

TextStyle? _subtitleStyle(TextTheme textTheme) =>
    textTheme.bodySmall?.copyWith(color: Colors.white70);

/// Height of one line of [style] at the user's font scale, laid out the way
/// the banner's `Text` widgets will be: inheriting from the surrounding
/// `Material`'s default text style, which is `bodyMedium`.
double _lineHeight(BuildContext context, TextStyle? style) {
  final base = Theme.of(context).textTheme.bodyMedium;
  final painter = TextPainter(
    text: TextSpan(text: 'X', style: base?.merge(style) ?? style),
    textDirection: Directionality.maybeOf(context) ?? TextDirection.ltr,
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final height = painter.height;
  painter.dispose();
  return height;
}

/// Loud, tappable warning that the guardians have announced this federation's
/// shutdown, by publishing a date, naming a successor, or both.
///
/// Sits directly under the balance on the dashboard, in the error colour, and
/// stays put while the transaction list scrolls: the point is that it cannot
/// be missed by someone who only ever glances at their balance.
class FederationExpiryBanner extends StatelessWidget {
  /// Unix seconds the guardians published as the shutdown time. Null when they
  /// only named a successor, which changes the wording but not the urgency.
  final BigInt? expiryTimestamp;
  final VoidCallback onTap;

  const FederationExpiryBanner({
    super.key,
    required this.expiryTimestamp,
    required this.onTap,
  });

  String _subtitle(BuildContext context) {
    final expiryTimestamp = this.expiryTimestamp;
    if (expiryTimestamp == null) {
      return context.l10n.federationExpiryBannerSubtitleSuccessor;
    }
    final expiry = expiryDateTime(expiryTimestamp);
    final date = DateFormat.yMMMd().format(expiry);
    return expiry.isBefore(DateTime.now())
        ? context.l10n.federationExpiryBannerSubtitlePast(date)
        : context.l10n.federationExpiryBannerSubtitle(date);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final warning = theme.colorScheme.error;

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: SizedBox(
        height: federationExpiryBannerExtent(context) - 8,
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
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          context.l10n.federationExpiryBannerTitle,
                          style: _titleStyle(
                            theme.textTheme,
                          )?.copyWith(color: warning),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _subtitle(context),
                          style: _subtitleStyle(theme.textTheme),
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
      ),
    );
  }
}
