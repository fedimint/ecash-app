import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/generated/app_localizations.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/screens/guardian_dashboard.dart';
import 'package:ecashapp/toast.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:qr_flutter/qr_flutter.dart';

const _cardColor = Color(0xFF1A1A1A);

String _formatSessionNumber(AppLocalizations l10n, BigInt sessionCount) =>
    NumberFormat.decimalPattern(l10n.localeName).format(sessionCount.toInt());

/// The session count a guardian last reported, labelled and grouped the way
/// the locale does. Null while the guardian has never answered.
String? formatGuardianSessionCount(
  AppLocalizations l10n,
  GuardianSessionStatus? status,
) {
  final sessionCount = status?.sessionCount;
  if (sessionCount == null) return null;
  return l10n.guardianSessionCount(_formatSessionNumber(l10n, sessionCount));
}

/// How long ago this wallet first saw the guardian report its current session
/// count, in the largest unit that fits. Null while the guardian has never
/// answered.
///
/// The age is what tells a guardian that is keeping up from one that is stuck,
/// since a session outcome carries no time of its own.
String? formatGuardianSessionAge(
  AppLocalizations l10n,
  GuardianSessionStatus? status, {
  DateTime? now,
}) {
  final firstSeenAt = status?.firstSeenAt;
  if (firstSeenAt == null) return null;
  return formatSessionAge(
    l10n,
    (now ?? DateTime.now()).difference(_fromUnixSeconds(firstSeenAt)),
  );
}

/// How long ago a session was first seen, abbreviated, in the largest unit
/// that fits.
String formatSessionAge(AppLocalizations l10n, Duration age) {
  // Also covers a negative age, which means the clock was set back since.
  if (age.inMinutes < 1) return l10n.guardianSessionAgeJustNow;
  if (age.inDays > 0) return l10n.guardianSessionAgeDays(age.inDays);
  if (age.inHours > 0) return l10n.guardianSessionAgeHours(age.inHours);
  return l10n.guardianSessionAgeMinutes(age.inMinutes);
}

DateTime _fromUnixSeconds(BigInt seconds) =>
    DateTime.fromMillisecondsSinceEpoch(seconds.toInt() * 1000);

/// Where a guardian stands in consensus relative to the others.
enum GuardianSyncState {
  /// Answered, and is on the most advanced session or the one before it.
  inSync,

  /// Answered, but trails the most advanced guardian by more than the spread
  /// between healthy guardians explains.
  behind,

  /// Cannot be reached at all.
  down,

  /// Reachable, but has not reported its session this round, so nothing is
  /// known about where it is now.
  unknown,
}

GuardianSyncState guardianSyncState({
  required bool online,
  required GuardianSessionStatus? session,
}) {
  if (!online) return GuardianSyncState.down;
  if (session == null || !session.fresh || session.sessionCount == null) {
    return GuardianSyncState.unknown;
  }
  return session.isBehind ? GuardianSyncState.behind : GuardianSyncState.inSync;
}

Color guardianSyncColor(ThemeData theme, GuardianSyncState state) =>
    switch (state) {
      GuardianSyncState.inSync => Colors.green,
      GuardianSyncState.behind => Colors.amber,
      GuardianSyncState.down => Colors.red,
      GuardianSyncState.unknown => Colors.grey,
    };

String guardianSyncLabel(AppLocalizations l10n, GuardianSyncState state) =>
    switch (state) {
      GuardianSyncState.inSync => l10n.guardianStateInSync,
      GuardianSyncState.behind => l10n.guardianStateBehind,
      GuardianSyncState.down => l10n.offline,
      GuardianSyncState.unknown => l10n.guardianStateUnknown,
    };

String _guardianSyncDetail(AppLocalizations l10n, GuardianSyncState state) =>
    switch (state) {
      GuardianSyncState.inSync => l10n.guardianStateInSyncDetail,
      GuardianSyncState.behind => l10n.guardianStateBehindDetail,
      GuardianSyncState.down => l10n.guardianStateDownDetail,
      GuardianSyncState.unknown => l10n.guardianStateUnknownDetail,
    };

/// A rounded tile with the guardian's initial, and a dot in the corner for
/// whether this wallet can reach it.
class GuardianAvatar extends StatelessWidget {
  final String name;
  final bool online;
  final double size;

  const GuardianAvatar({
    super.key,
    required this.name,
    required this.online,
    this.size = 40,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final trimmed = name.trim();
    final initial =
        trimmed.isEmpty ? '?' : trimmed.characters.first.toUpperCase();
    final dotSize = size * 0.3;

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: size,
            height: size,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(size * 0.25),
            ),
            child: Text(
              initial,
              style: TextStyle(
                color: theme.colorScheme.primary,
                fontSize: size * 0.42,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Positioned(
            right: -dotSize * 0.2,
            bottom: -dotSize * 0.2,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 400),
              width: dotSize,
              height: dotSize,
              decoration: BoxDecoration(
                color: online ? Colors.green : Colors.red,
                shape: BoxShape.circle,
                border: Border.all(
                  color: theme.scaffoldBackgroundColor,
                  width: 2,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A small coloured pill, used for a guardian's place in consensus and for
/// how this wallet reaches it.
class GuardianPill extends StatelessWidget {
  final String label;
  final Color color;

  const GuardianPill({super.key, required this.label, required this.color});

  GuardianPill.sync(
    AppLocalizations l10n,
    ThemeData theme,
    GuardianSyncState state, {
    Key? key,
  }) : this(
         key: key,
         label: guardianSyncLabel(l10n, state),
         color: guardianSyncColor(theme, state),
       );

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Everything this wallet knows about one guardian, plus its invite code and
/// the way into its admin dashboard.
///
/// Kept current from the peer and session streams the federation info screen
/// already follows, so nothing extra is asked of the guardians while it is
/// open.
class GuardianScreen extends StatefulWidget {
  final FederationSelector fed;

  /// The guardian as it was when tapped; shown until [peers] has it.
  final PeerStatus peer;
  final ValueListenable<List<PeerStatus>?> peers;
  final ValueListenable<Map<int, GuardianSessionStatus>> sessions;

  /// A federation that has not been joined yet: there is no invite code to
  /// hand out and no dashboard to log in to.
  final bool joinable;

  const GuardianScreen({
    super.key,
    required this.fed,
    required this.peer,
    required this.peers,
    required this.sessions,
    required this.joinable,
  });

  @override
  State<GuardianScreen> createState() => _GuardianScreenState();
}

class _GuardianScreenState extends State<GuardianScreen> {
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.peers, widget.sessions]),
      builder: (context, _) {
        final peers = widget.peers.value ?? const <PeerStatus>[];
        final peer = peers.firstWhere(
          (p) => p.peerId == widget.peer.peerId,
          orElse: () => widget.peer,
        );
        final session = widget.sessions.value[peer.peerId];
        final onlineCount = peers.where((p) => p.online).length;
        final isFederationOnline =
            peers.isNotEmpty && onlineCount >= threshold(peers.length);
        return _buildScaffold(peer, session, isFederationOnline);
      },
    );
  }

  Widget _buildScaffold(
    PeerStatus peer,
    GuardianSessionStatus? session,
    bool isFederationOnline,
  ) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final state = guardianSyncState(online: peer.online, session: session);

    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Text(peer.name, overflow: TextOverflow.ellipsis),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _buildHeader(theme, peer, state),
                  const SizedBox(height: 28),
                  _sectionHeader(theme, l10n.guardianConsensusSection),
                  const SizedBox(height: 8),
                  _buildConsensusCard(theme, state, session),
                  const SizedBox(height: 24),
                  _sectionHeader(theme, l10n.guardianConnectionSection),
                  const SizedBox(height: 8),
                  _buildConnectionCard(theme, peer),
                  if (!widget.joinable && isFederationOnline) ...[
                    const SizedBox(height: 24),
                    _sectionHeader(theme, l10n.inviteCode),
                    const SizedBox(height: 8),
                    _actionTile(
                      theme: theme,
                      icon: Icons.copy,
                      title: l10n.copyInviteCode,
                      onTap: () => _copyInviteCode(peer),
                    ),
                    const SizedBox(height: 8),
                    _actionTile(
                      theme: theme,
                      icon: Icons.qr_code,
                      title: l10n.viewInviteCode,
                      onTap: () => _showInviteCode(peer),
                    ),
                  ],
                ],
              ),
            ),
            if (!widget.joinable) _buildDashboardButton(theme, peer),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(
    ThemeData theme,
    PeerStatus peer,
    GuardianSyncState state,
  ) {
    final l10n = context.l10n;
    return Column(
      children: [
        const SizedBox(height: 8),
        GuardianAvatar(name: peer.name, online: peer.online, size: 76),
        const SizedBox(height: 16),
        Text(
          peer.name,
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        if (peer.version != null) ...[
          const SizedBox(height: 4),
          Text(
            l10n.versionLabel(peer.version!),
            style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
          ),
        ],
        const SizedBox(height: 12),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            GuardianPill.sync(l10n, theme, state),
            if (peer.online)
              GuardianPill(
                label: _connectivityLabel(peer.connectivity),
                color: _connectivityColor(peer.connectivity),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildConsensusCard(
    ThemeData theme,
    GuardianSyncState state,
    GuardianSessionStatus? session,
  ) {
    final l10n = context.l10n;
    final color = guardianSyncColor(theme, state);
    final sessionCount = session?.sessionCount;
    final age = formatGuardianSessionAge(l10n, session);
    // Faded until the guardian has answered this round: what is on disk says
    // where it was, not where it is.
    final stale = session != null && !session.fresh;

    return _card(
      children: [
        Row(
          children: [
            Icon(Icons.circle, size: 10, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _guardianSyncDetail(l10n, state),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        if (sessionCount != null) ...[
          const SizedBox(height: 8),
          _statRow(
            theme,
            l10n.guardianSessionLabel,
            _formatSessionNumber(l10n, sessionCount),
            faded: stale,
          ),
        ],
        if (age != null)
          _statRow(theme, l10n.guardianFirstSeenLabel, age, faded: stale),
        if (state == GuardianSyncState.behind)
          _statRow(
            theme,
            l10n.guardianSessionsBehindLabel,
            _formatSessionNumber(l10n, session!.sessionsBehind),
            valueColor: color,
          ),
      ],
    );
  }

  Widget _buildConnectionCard(ThemeData theme, PeerStatus peer) {
    final l10n = context.l10n;
    return _card(
      children: [
        _statRow(
          theme,
          l10n.guardianStatusLabel,
          peer.online ? l10n.guardianOnline : l10n.offline,
          valueColor: peer.online ? Colors.green : Colors.red,
        ),
        if (peer.online)
          _statRow(
            theme,
            l10n.guardianConnectionTypeLabel,
            _connectivityLabel(peer.connectivity),
          ),
        if (peer.version != null)
          _statRow(theme, l10n.guardianVersionLabel, peer.version!),
        const SizedBox(height: 8),
        Divider(height: 1, color: Colors.white.withValues(alpha: 0.08)),
        const SizedBox(height: 8),
        Text(
          l10n.guardianUrlLabel,
          style: theme.textTheme.bodyMedium?.copyWith(color: Colors.grey),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: SelectableText(
                peer.url,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.85),
                ),
              ),
            ),
            IconButton(
              tooltip: l10n.copyTitle(l10n.guardianUrlLabel),
              icon: const Icon(Icons.copy, size: 18),
              visualDensity: VisualDensity.compact,
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: peer.url));
                if (!mounted) return;
                ToastService().show(
                  message: context.l10n.copiedText(
                    context.l10n.guardianUrlLabel,
                  ),
                  duration: const Duration(seconds: 3),
                  onTap: () {},
                  icon: const Icon(Icons.check),
                );
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildDashboardButton(ThemeData theme, PeerStatus peer) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!peer.online) ...[
            Text(
              context.l10n.guardianOfflineLoginHint,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
            ),
            const SizedBox(height: 8),
          ],
          ElevatedButton.icon(
            onPressed: peer.online ? () => _onLoginPressed(peer) : null,
            icon: const Icon(Icons.admin_panel_settings_outlined),
            label: Text(context.l10n.guardianOpenDashboard),
            style: ElevatedButton.styleFrom(
              backgroundColor: theme.colorScheme.primary,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              textStyle: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --- Building blocks ---

  Widget _sectionHeader(ThemeData theme, String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        title.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: Colors.grey,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _card({required List<Widget> children}) {
    return Container(
      decoration: BoxDecoration(
        color: _cardColor,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  Widget _statRow(
    ThemeData theme,
    String label,
    String value, {
    Color? valueColor,
    bool faded = false,
  }) {
    final alpha = faded ? 0.5 : 1.0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(color: Colors.grey),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: (valueColor ?? theme.colorScheme.onSurface).withValues(
                alpha: alpha,
              ),
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionTile({
    required ThemeData theme,
    required IconData icon,
    required String title,
    required VoidCallback onTap,
  }) {
    return Material(
      color: _cardColor,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 20, color: theme.colorScheme.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Icon(Icons.chevron_right, color: Colors.grey),
            ],
          ),
        ),
      ),
    );
  }

  Color _connectivityColor(PeerConnectivity c) => switch (c) {
    PeerConnectivity.direct => Colors.green,
    PeerConnectivity.relay => Colors.amber,
    PeerConnectivity.mixed => Colors.teal,
    PeerConnectivity.tor => Colors.deepPurple,
    PeerConnectivity.unknown => Colors.grey,
  };

  String _connectivityLabel(PeerConnectivity c) => switch (c) {
    PeerConnectivity.direct => context.l10n.connectionDirect,
    PeerConnectivity.relay => context.l10n.connectionRelay,
    PeerConnectivity.mixed => context.l10n.connectionMixed,
    PeerConnectivity.tor => context.l10n.connectionTor,
    PeerConnectivity.unknown => context.l10n.connectionUnknown,
  };

  // --- Invite code ---

  Future<String?> _fetchInviteCode(PeerStatus peer) async {
    try {
      return await getInviteCode(
        federationId: widget.fed.federationId,
        peer: peer.peerId,
      );
    } catch (e) {
      AppLogger.instance.error("Error getting invite code: $e");
      if (mounted) {
        ToastService().show(
          message: context.l10n.couldNotGetInviteCode,
          duration: const Duration(seconds: 5),
          onTap: () {},
          icon: const Icon(Icons.error),
        );
      }
      return null;
    }
  }

  Future<void> _copyInviteCode(PeerStatus peer) async {
    final inviteCode = await _fetchInviteCode(peer);
    if (inviteCode == null || !mounted) return;
    await Clipboard.setData(ClipboardData(text: inviteCode));
    if (!mounted) return;
    ToastService().show(
      message: context.l10n.inviteCodeCopied(peer.name),
      duration: const Duration(seconds: 5),
      onTap: () {},
      icon: const Icon(Icons.check),
    );
  }

  Future<void> _showInviteCode(PeerStatus peer) async {
    final inviteCode = await _fetchInviteCode(peer);
    if (inviteCode == null || !mounted) return;
    showDialog(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: Center(
              child: Text(
                dialogContext.l10n.inviteCode,
                textAlign: TextAlign.center,
              ),
            ),
            content: AspectRatio(
              aspectRatio: 1,
              child: GestureDetector(
                onTap: () => _showFullscreenQr(dialogContext, inviteCode),
                child: QrImageView(
                  data: inviteCode,
                  version: QrVersions.auto,
                  backgroundColor: Colors.white,
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: Text(dialogContext.l10n.close),
              ),
            ],
          ),
    );
  }

  void _showFullscreenQr(BuildContext context, String inviteCode) {
    showDialog(
      context: context,
      builder:
          (fullscreenContext) => Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: EdgeInsets.zero,
            child: GestureDetector(
              onTap:
                  () =>
                      Navigator.of(
                        fullscreenContext,
                        rootNavigator: true,
                      ).pop(),
              child: Container(
                width: double.infinity,
                height: double.infinity,
                color: Colors.black.withValues(alpha: 0.9),
                child: Center(
                  child: QrImageView(
                    data: inviteCode,
                    version: QrVersions.auto,
                    backgroundColor: Colors.white,
                    size: MediaQuery.of(fullscreenContext).size.width * 0.9,
                  ),
                ),
              ),
            ),
          ),
    );
  }

  // --- Guardian dashboard login ---

  Future<void> _onLoginPressed(PeerStatus peer) async {
    final passwordController = TextEditingController();

    await showDialog(
      context: context,
      builder: (dialogContext) {
        bool isVerifying = false;
        String? errorText;

        return StatefulBuilder(
          builder: (sbContext, setState) {
            Future<void> submit() async {
              final password = passwordController.text;
              if (password.isEmpty || isVerifying) return;
              setState(() {
                isVerifying = true;
                errorText = null;
              });

              try {
                final ok = await guardianLogin(
                  federationId: widget.fed.federationId,
                  peer: peer.peerId,
                  password: password,
                );
                if (!sbContext.mounted) return;
                if (!ok) {
                  setState(() {
                    isVerifying = false;
                    errorText = sbContext.l10n.guardianInvalidPassword;
                  });
                  return;
                }
                Navigator.of(dialogContext).pop();
                if (!mounted) return;
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder:
                        (_) => GuardianDashboardScreen(
                          fed: widget.fed,
                          peer: peer,
                          password: password,
                        ),
                  ),
                );
              } catch (e) {
                AppLogger.instance.error("Guardian login failed: $e");
                if (!sbContext.mounted) return;
                setState(() {
                  isVerifying = false;
                  errorText = sbContext.l10n.guardianLoginFailed;
                });
              }
            }

            return AlertDialog(
              title: Text(sbContext.l10n.guardianDashboardTitle),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(sbContext.l10n.guardianLoginPrompt(peer.name)),
                  const SizedBox(height: 12),
                  TextField(
                    controller: passwordController,
                    obscureText: true,
                    autofocus: true,
                    enabled: !isVerifying,
                    decoration: InputDecoration(
                      labelText: sbContext.l10n.guardianPasswordLabel,
                      errorText: errorText,
                    ),
                    onSubmitted: (_) => submit(),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed:
                      isVerifying
                          ? null
                          : () => Navigator.of(dialogContext).pop(),
                  child: Text(sbContext.l10n.cancel),
                ),
                TextButton(
                  onPressed: isVerifying ? null : submit,
                  child:
                      isVerifying
                          ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                          : Text(sbContext.l10n.logIn),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
