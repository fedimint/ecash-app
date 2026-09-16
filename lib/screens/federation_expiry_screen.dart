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

/// Explains a guardian-announced shutdown and walks the user out of the
/// federation: move the balance, drop the Lightning Address, optionally join
/// the successor, leave. Each step links to the flow that does it, and steps
/// that no longer apply fall off the list.
///
/// Reached from the dashboard's expiry banner. The facts shown come from the
/// caller, so the screen opens without a network call; once a step's flow
/// returns, the balance and address are re-read through the loaders.
class FederationExpiryScreen extends StatefulWidget {
  final String federationName;

  /// Unix seconds the guardians published as the shutdown time. Null when they
  /// only named a successor.
  final BigInt? expiryTimestamp;

  /// Invite code of the federation the guardians want users to move to. Null
  /// when they only published a date.
  final String? successorInvite;

  /// Balance and Lightning Address (`user@domain`) as the dashboard last saw
  /// them. The screen starts from these and refreshes through [loadBalance]
  /// and [loadLightningAddress] after each step.
  final BigInt? balanceMsats;
  final String? lightningAddress;
  final Future<BigInt?> Function() loadBalance;
  final Future<String?> Function() loadLightningAddress;

  /// Opens the on-chain send flow for this federation, completing once the
  /// user is back here.
  final Future<void> Function() onSendOnchain;

  /// Opens the Lightning Address screen with this federation selected,
  /// completing once the user is back here.
  final Future<void> Function() onOpenLightningAddress;

  /// Selects a freshly joined federation. Threaded from the app root because
  /// only the root can change which federation is selected.
  final void Function(FederationSelector fed, bool recovering) onJoin;

  /// Confirms and leaves this federation. Supplied by the dashboard, which
  /// has the federation id and the app root's callback this needs.
  final Future<void> Function() onLeaveFederation;

  const FederationExpiryScreen({
    super.key,
    required this.federationName,
    required this.expiryTimestamp,
    required this.successorInvite,
    required this.balanceMsats,
    required this.lightningAddress,
    required this.loadBalance,
    required this.loadLightningAddress,
    required this.onSendOnchain,
    required this.onOpenLightningAddress,
    required this.onJoin,
    required this.onLeaveFederation,
  });

  @override
  State<FederationExpiryScreen> createState() => _FederationExpiryScreenState();
}

final _oneSatMsats = BigInt.from(1000);

class _FederationExpiryScreenState extends State<FederationExpiryScreen> {
  late BigInt? _balanceMsats = widget.balanceMsats;
  late String? _lightningAddress = widget.lightningAddress;

  /// False until both loaders have succeeded once. The dashboard hands over
  /// whatever it had loaded when the banner was tapped, which can be nothing
  /// yet, and neither a missing value nor a failed read may pass for
  /// "nothing to do" while Leave sits below.
  bool _loaded = false;

  /// One step's flow at a time; every link is disabled while one runs.
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  /// Runs a step's flow, then re-reads what it may have changed so the list
  /// reflects the new state when the user lands back here.
  Future<void> _run(Future<void> Function() flow) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await flow();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted) await _refresh();
  }

  Future<void> _refresh() async {
    var balance = _balanceMsats;
    var address = _lightningAddress;
    var complete = true;
    try {
      balance = await widget.loadBalance();
    } catch (e) {
      complete = false;
      AppLogger.instance.warn('Could not refresh balance: $e');
    }
    try {
      address = await widget.loadLightningAddress();
    } catch (e) {
      complete = false;
      AppLogger.instance.warn('Could not refresh Lightning Address: $e');
    }
    if (!mounted) return;
    setState(() {
      _balanceMsats = balance;
      _lightningAddress = address;
      // Only a pair of successful reads settles which steps apply. Once
      // settled, a later failed refresh keeps the last known values.
      if (complete) _loaded = true;
    });
  }

  /// Previews the successor so the user sees its guardians before committing,
  /// then hands the joined federation to the app root and returns to the
  /// dashboard, which by then shows the successor.
  Future<void> _joinSuccessor() async {
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
    if (!mounted || joined == null) return;

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

  Future<void> _findFederation() => Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => Discover(onJoin: widget.onJoin, showAppBar: true),
    ),
  );

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
    // Below one sat there is nothing an on-chain send can carry.
    final hasBalance = _balanceMsats != null && _balanceMsats! >= _oneSatMsats;
    final lightningAddress = _lightningAddress;
    final bitcoinDisplay = context.select<PreferencesProvider, BitcoinDisplay>(
      (prefs) => prefs.bitcoinDisplay,
    );

    final steps = <_StepSpec>[
      if (hasBalance)
        _StepSpec(
          text: l10n.federationExpiryStepMoveFunds,
          action: l10n.federationExpirySendOnchain,
          icon: Icons.upload,
          onTap: () => _run(widget.onSendOnchain),
        ),
      if (lightningAddress != null)
        _StepSpec(
          text: l10n.federationExpiryStepRemoveLightningAddress(
            lightningAddress,
          ),
          action: l10n.federationExpiryManageLightningAddress,
          icon: Icons.flash_on,
          onTap: () => _run(widget.onOpenLightningAddress),
        ),
      if (hasSuccessor)
        _StepSpec(
          text: l10n.federationExpiryStepJoinSuccessor,
          action: l10n.federationExpiryJoinSuccessor,
          icon: Icons.login,
          onTap: () => _run(_joinSuccessor),
        )
      else
        _StepSpec(
          text: l10n.federationExpiryStepJoinAnother,
          action: l10n.federationExpiryFindFederation,
          icon: Icons.search,
          onTap: () => _run(_findFederation),
        ),
      _StepSpec(
        text: l10n.federationExpiryStepLeave,
        action: l10n.leaveFederation,
        icon: Icons.logout,
        onTap: () => _run(widget.onLeaveFederation),
        destructive: true,
      ),
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
        formatBalance(_balanceMsats, false, bitcoinDisplay),
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
            if (!_loaded)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              )
            else
              for (final (index, step) in steps.indexed)
                _Step(
                  number: index + 1,
                  text: step.text,
                  actionLabel: step.action,
                  icon: step.icon,
                  destructive: step.destructive,
                  onPressed: _busy ? null : step.onTap,
                ),
          ],
        ),
      ),
    );
  }
}

/// One checklist entry: what to do, and the link that does it.
class _StepSpec {
  final String text;
  final String action;
  final IconData icon;
  final Future<void> Function() onTap;

  /// Rendered in the error colour, for the step that cannot be undone.
  final bool destructive;

  const _StepSpec({
    required this.text,
    required this.action,
    required this.icon,
    required this.onTap,
    this.destructive = false,
  });
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
  final String actionLabel;
  final IconData icon;
  final bool destructive;

  /// Null while another step's flow is running, which disables the link.
  final VoidCallback? onPressed;

  const _Step({
    required this.number,
    required this.text,
    required this.actionLabel,
    required this.icon,
    required this.destructive,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = destructive ? theme.colorScheme.error : null;
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
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: onPressed,
                    icon: Icon(icon, size: 18),
                    label: Text(actionLabel),
                    style: TextButton.styleFrom(
                      foregroundColor: accent,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
