import 'package:ecashapp/db.dart';
import 'package:ecashapp/discover.dart';
import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/providers/preferences_provider.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

/// Converts the raw `federation_expiry_timestamp` (Unix *seconds*, as the
/// guardians publish it) into a local [DateTime].
DateTime expiryDateTime(BigInt expiryTimestamp) =>
    DateTime.fromMillisecondsSinceEpoch(expiryTimestamp.toInt() * 1000);

/// Coarse "how long is left" text, in the largest unit that still reads as a
/// number the user can act on. Deliberately not a precise countdown: this is a
/// deadline to plan around, not a timer.
String formatTimeUntilExpiry(BuildContext context, DateTime expiry) {
  final remaining = expiry.difference(DateTime.now());
  if (remaining.isNegative) return context.l10n.federationExpiryPassed;
  if (remaining.inDays > 0) {
    return context.l10n.federationExpiryInDays(remaining.inDays);
  }
  if (remaining.inHours > 0) {
    return context.l10n.federationExpiryInHours(remaining.inHours);
  }
  return context.l10n.federationExpiryInMinutes(remaining.inMinutes);
}

/// Explains a guardian-announced shutdown and what the user has to do about it.
///
/// Reached from the dashboard's expiry banner. Everything here is read from the
/// federation meta the caller already has, so the screen never blocks on a
/// network call — a user opening it because their money is at stake should not
/// meet a spinner.
class FederationExpiryScreen extends StatelessWidget {
  final FederationSelector fed;

  /// Unix seconds the guardians published as the shutdown time.
  final BigInt expiryTimestamp;

  /// Current balance, so the user can see what still has to be moved without
  /// navigating back. Null while the dashboard is still loading it.
  final BigInt? balanceMsats;

  /// Opens the join flow. Threaded down from the app root because joining
  /// changes which federation is selected, which only the root can do.
  final void Function(FederationSelector fed, bool recovering) onJoin;

  /// Pops back to the dashboard and starts a send. Null when there is nothing
  /// to move.
  final VoidCallback? onMoveFunds;

  /// The Lightning Address registered against this federation, if any, as
  /// `user@domain`. It keeps resolving to this federation after the shutdown is
  /// announced — the registration lives on the recurringd server, not here — so
  /// the screen has to say so rather than claim all receiving has stopped.
  final String? lightningAddress;

  const FederationExpiryScreen({
    super.key,
    required this.fed,
    required this.expiryTimestamp,
    required this.balanceMsats,
    required this.onJoin,
    this.onMoveFunds,
    this.lightningAddress,
  });

  void _onFindFederation(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Discover(onJoin: onJoin, showAppBar: true),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final expiry = expiryDateTime(expiryTimestamp);
    final hasExpired = expiry.isBefore(DateTime.now());
    final warning = theme.colorScheme.error;

    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.federationExpiryTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
          children: [
            Center(
              child: Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: warning.withValues(alpha: 0.12),
                ),
                child: Icon(
                  Icons.warning_amber_rounded,
                  size: 48,
                  color: warning,
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              hasExpired
                  ? context.l10n.federationExpiryHeadlinePast(
                    fed.federationName,
                  )
                  : context.l10n.federationExpiryHeadline(fed.federationName),
              style: theme.textTheme.headlineSmall?.copyWith(
                color: warning,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            _FactsCard(
              rows: [
                (
                  hasExpired
                      ? context.l10n.federationExpiryClosedOn
                      : context.l10n.federationExpiryClosesOn,
                  DateFormat.yMMMMd().add_jm().format(expiry),
                ),
                (
                  context.l10n.federationExpiryTimeRemaining,
                  formatTimeUntilExpiry(context, expiry),
                ),
                (
                  context.l10n.federationExpiryYourBalance,
                  formatBalance(
                    balanceMsats,
                    false,
                    context.select<PreferencesProvider, BitcoinDisplay>(
                      (prefs) => prefs.bitcoinDisplay,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Text(
              context.l10n.federationExpiryExplanation,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
            ),
            const SizedBox(height: 28),
            Text(
              context.l10n.federationExpiryWhatToDo,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            _Step(
              number: 1,
              text: context.l10n.federationExpiryStepReceivesOff,
              note:
                  lightningAddress != null
                      ? context.l10n.federationExpiryLightningAddressNote(
                        lightningAddress!,
                      )
                      : null,
            ),
            _Step(number: 2, text: context.l10n.federationExpiryStepMoveFunds),
            _Step(
              number: 3,
              text: context.l10n.federationExpiryStepJoinAnother,
            ),
            const SizedBox(height: 28),
            if (onMoveFunds != null) ...[
              OutlinedButton.icon(
                onPressed: () {
                  Navigator.of(context).pop();
                  onMoveFunds!();
                },
                icon: const Icon(Icons.upload),
                label: Text(context.l10n.federationExpiryMoveFunds),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
              ),
              const SizedBox(height: 12),
            ],
            FilledButton.icon(
              onPressed: () => _onFindFederation(context),
              icon: const Icon(Icons.search),
              label: Text(context.l10n.federationExpiryFindFederation),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The three headline facts, as label/value rows on one surface.
class _FactsCard extends StatelessWidget {
  final List<(String, String)> rows;

  const _FactsCard({required this.rows});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          for (final (index, row) in rows.indexed) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    row.$1,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: Colors.grey,
                    ),
                  ),
                  const Spacer(),
                  Flexible(
                    child: Text(
                      row.$2,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      textAlign: TextAlign.end,
                    ),
                  ),
                ],
              ),
            ),
            if (index != rows.length - 1)
              Divider(height: 1, color: Colors.grey.withValues(alpha: 0.2)),
          ],
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  final int number;
  final String text;

  /// Caveat shown under the step, set apart from it. Used where the general
  /// statement has an exception the user needs to act on.
  final String? note;

  const _Step({required this.number, required this.text, this.note});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: theme.colorScheme.primary.withValues(alpha: 0.15),
            ),
            child: Text(
              '$number', // i18n-ignore - list numbering, not prose
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  text,
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
                ),
                if (note != null) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.error.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      note!,
                      style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
