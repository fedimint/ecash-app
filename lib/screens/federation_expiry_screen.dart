import 'package:ecashapp/db.dart';
import 'package:ecashapp/discover.dart';
import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/generated/app_localizations.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/providers/preferences_provider.dart';
import 'package:ecashapp/screens/federation_info_screen.dart';
import 'package:ecashapp/toast.dart';
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
String formatTimeUntilExpiry(
  AppLocalizations l10n,
  DateTime expiry, {
  DateTime? now,
}) {
  final remaining = expiry.difference(now ?? DateTime.now());
  if (remaining.isNegative) return l10n.federationExpiryPassed;
  if (remaining.inDays > 0) {
    return l10n.federationExpiryInDays(remaining.inDays);
  }
  if (remaining.inHours > 0) {
    return l10n.federationExpiryInHours(remaining.inHours);
  }
  return l10n.federationExpiryInMinutes(remaining.inMinutes);
}

/// Explains a guardian-announced shutdown and what the user has to do about it.
///
/// Reached from the dashboard's expiry banner. Everything here is read from the
/// federation meta the caller already has, so the screen never blocks on a
/// network call: a user opening it because their money is at stake should not
/// meet a spinner.
class FederationExpiryScreen extends StatefulWidget {
  final String federationName;

  /// Unix seconds the guardians published as the shutdown time. Null when they
  /// only named a successor.
  final BigInt? expiryTimestamp;

  /// Invite code of the federation the guardians want users to move to. Null
  /// when they only published a date.
  final String? successorInvite;

  /// Current balance, so the user can see what still has to be moved without
  /// navigating back. Null while the dashboard is still loading it.
  final BigInt? balanceMsats;

  /// Selects a freshly joined federation. Threaded down from the app root
  /// because only the root can change which federation is selected.
  final void Function(FederationSelector fed, bool recovering) onJoin;

  /// Pops back to the dashboard and starts a send. Null when there is nothing
  /// to move.
  final VoidCallback? onMoveFunds;

  /// The Lightning Address registered against this federation, if any, as
  /// `user@domain`. Registrations are per federation and live on the address
  /// server, so it keeps paying in here after the shutdown is announced and
  /// setting one up elsewhere does not retire it. Removing it gets its own
  /// step.
  final String? lightningAddress;

  const FederationExpiryScreen({
    super.key,
    required this.federationName,
    required this.expiryTimestamp,
    required this.successorInvite,
    required this.balanceMsats,
    required this.onJoin,
    this.onMoveFunds,
    this.lightningAddress,
  });

  @override
  State<FederationExpiryScreen> createState() => _FederationExpiryScreenState();
}

class _FederationExpiryScreenState extends State<FederationExpiryScreen> {
  // Guards against pushing the preview route twice while one is already opening.
  bool _isOpeningPreview = false;

  void _onFindFederation() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Discover(onJoin: widget.onJoin, showAppBar: true),
      ),
    );
  }

  /// Opens the successor's preview so the user sees its guardians before
  /// committing, then hands the joined federation to the app root and returns
  /// to the dashboard, which by then shows the successor.
  Future<void> _onJoinSuccessor() async {
    if (_isOpeningPreview) return;
    setState(() => _isOpeningPreview = true);

    final joined = await Navigator.push<(FederationSelector, bool)>(
      context,
      MaterialPageRoute(
        builder:
            (_) => FederationInfoScreen(
              inviteCode: widget.successorInvite,
              joinable: true,
              onLeaveFederation: () {},
            ),
      ),
    );

    if (!mounted) return;
    setState(() => _isOpeningPreview = false);
    if (joined == null) return;

    final (fed, recovering) = joined;
    final message = context.l10n.joinedFederation(fed.federationName);
    widget.onJoin(fed, recovering);
    Navigator.popUntil(context, (route) => route.isFirst);
    ToastService().show(
      message: message,
      duration: const Duration(seconds: 5),
      onTap: () {},
      icon: const Icon(Icons.info),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final warning = theme.colorScheme.error;
    final expiryTimestamp = widget.expiryTimestamp;
    final expiry =
        expiryTimestamp != null ? expiryDateTime(expiryTimestamp) : null;
    final hasExpired = expiry != null && expiry.isBefore(DateTime.now());
    final hasSuccessor = widget.successorInvite != null;
    final bitcoinDisplay = context.select<PreferencesProvider, BitcoinDisplay>(
      (prefs) => prefs.bitcoinDisplay,
    );

    final steps = <String>[
      l10n.federationExpiryStepReceivesOff,
      if (widget.lightningAddress != null)
        l10n.federationExpiryStepRemoveLightningAddress(
          widget.lightningAddress!,
        ),
      l10n.federationExpiryStepMoveFunds,
      hasSuccessor
          ? l10n.federationExpiryStepJoinSuccessor
          : l10n.federationExpiryStepJoinAnother,
    ];

    final facts = <(String, String)>[
      if (expiry != null)
        (
          hasExpired
              ? l10n.federationExpiryClosedOn
              : l10n.federationExpiryClosesOn,
          DateFormat.yMMMMd().add_jm().format(expiry),
        ),
      if (expiry != null && !hasExpired)
        (
          l10n.federationExpiryTimeRemaining,
          formatTimeUntilExpiry(l10n, expiry),
        ),
      (
        l10n.federationExpiryYourBalance,
        formatBalance(widget.balanceMsats, false, bitcoinDisplay),
      ),
    ];

    return Scaffold(
      appBar: AppBar(title: Text(l10n.federationExpiryTitle)),
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
                  ? l10n.federationExpiryHeadlinePast(widget.federationName)
                  : l10n.federationExpiryHeadline(widget.federationName),
              style: theme.textTheme.headlineSmall?.copyWith(
                color: warning,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            _FactsCard(rows: facts),
            const SizedBox(height: 24),
            Text(
              l10n.federationExpiryExplanation,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
            ),
            const SizedBox(height: 28),
            Text(
              l10n.federationExpiryWhatToDo,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            for (final (index, text) in steps.indexed)
              _Step(number: index + 1, text: text),
            const SizedBox(height: 28),
            if (widget.onMoveFunds != null) ...[
              OutlinedButton.icon(
                onPressed: () {
                  Navigator.of(context).pop();
                  widget.onMoveFunds!();
                },
                icon: const Icon(Icons.upload),
                label: Text(l10n.federationExpiryMoveFunds),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (hasSuccessor)
              FilledButton.icon(
                onPressed: _isOpeningPreview ? null : _onJoinSuccessor,
                icon: const Icon(Icons.login),
                label: Text(l10n.federationExpiryJoinSuccessor),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
              )
            else
              FilledButton.icon(
                onPressed: _onFindFederation,
                icon: const Icon(Icons.search),
                label: Text(l10n.federationExpiryFindFederation),
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

/// The headline facts, as label/value rows on one surface.
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

  const _Step({required this.number, required this.text});

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
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}
