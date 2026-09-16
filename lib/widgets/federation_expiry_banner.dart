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

/// Loud warning that the guardians have announced this federation's shutdown,
/// by publishing a date, naming a successor, or both.
///
/// On the dashboard it sits directly under the balance, in the error colour,
/// stays put while the transaction list scrolls and opens the details on tap:
/// the point is that it cannot be missed by someone who only ever glances at
/// their balance. On a join preview it is informational ([onTap] null), lays
/// out at its natural height ([compact] false) and carries a [note] telling
/// the reader why they might still want to join.
class FederationExpiryBanner extends StatelessWidget {
  /// Unix seconds the guardians published as the shutdown time. Null when they
  /// only named a successor, which changes the wording but not the urgency.
  final BigInt? expiryTimestamp;

  /// Opens the details. Null makes the banner informational: no chevron, no
  /// "tap for details".
  final VoidCallback? onTap;

  /// True for the fixed, single-line layout the pinned dashboard header needs
  /// (see [federationExpiryBannerExtent]); false lets the second line wrap.
  final bool compact;

  /// Extra sentence appended to the second line.
  final String? note;

  const FederationExpiryBanner({
    super.key,
    required this.expiryTimestamp,
    required this.onTap,
    this.compact = true,
    this.note,
  });

  String _subtitle(BuildContext context) {
    final l10n = context.l10n;
    final expiryTimestamp = this.expiryTimestamp;
    final String base;
    if (expiryTimestamp == null) {
      base = l10n.federationExpiryBannerSubtitleSuccessor;
    } else {
      final expiry = expiryDateTime(expiryTimestamp);
      final date = DateFormat.yMMMd().format(expiry);
      base =
          expiry.isBefore(DateTime.now())
              ? l10n.federationExpiryBannerSubtitlePast(date)
              : l10n.federationExpiryBannerSubtitle(date);
    }
    return [
      base,
      if (onTap != null) l10n.federationExpiryBannerTap,
      if (note != null) note!,
    ].join(' ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final warning = theme.colorScheme.error;

    final card = Material(
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
                      // A successor with no date is a recommendation to move,
                      // not a shutdown; the locks treat it that way too.
                      expiryTimestamp == null
                          ? context.l10n.federationExpiryBannerTitleSuccessor
                          : context.l10n.federationExpiryBannerTitle,
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
                      maxLines: compact ? 1 : 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (onTap != null)
                Icon(Icons.chevron_right, color: warning, size: 20),
            ],
          ),
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child:
          compact
              ? SizedBox(
                height: federationExpiryBannerExtent(context) - 8,
                child: card,
              )
              : card,
    );
  }
}
