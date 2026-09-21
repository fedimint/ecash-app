import 'dart:async';

import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/generated/app_localizations.dart';
import 'package:ecashapp/screens/guardian_dashboard.dart';
import 'package:ecashapp/widgets/federation_utxo_list.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/nwc.dart';
import 'package:ecashapp/toast.dart';
import 'package:ecashapp/utils.dart';
import 'package:ecashapp/widgets/federation_expiry_banner.dart';
import 'package:ecashapp/widgets/gateways.dart';
import 'package:ecashapp/widgets/leave_federation_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:qr_flutter/qr_flutter.dart';

enum _InfoSection { guardians, utxos, gateways }

/// The session count a guardian last reported, labelled and grouped the way
/// the locale does. Null while the guardian has never answered.
String? formatGuardianSessionCount(
  AppLocalizations l10n,
  GuardianSessionStatus? status,
) {
  final sessionCount = status?.sessionCount;
  if (sessionCount == null) return null;
  return l10n.guardianSessionCount(
    NumberFormat.decimalPattern(l10n.localeName).format(sessionCount.toInt()),
  );
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

String _formatLongDuration(AppLocalizations l10n, Duration duration) {
  if (duration.inDays > 0) return l10n.federationExpiryInDays(duration.inDays);
  if (duration.inHours > 0) {
    return l10n.federationExpiryInHours(duration.inHours);
  }
  return l10n.federationExpiryInMinutes(duration.inMinutes);
}

DateTime _fromUnixSeconds(BigInt seconds) =>
    DateTime.fromMillisecondsSinceEpoch(seconds.toInt() * 1000);

/// How long the most advanced session may go without a successor before
/// consensus is reported as stalled. A session lasts about three minutes;
/// the margin is for federations configured with longer ones and for the
/// half minute between two rounds of requests.
const consensusStalledAfter = Duration(minutes: 10);

/// Where a guardian stands relative to the others.
enum GuardianSyncState {
  /// Answered, and is on the most advanced session or the one before it.
  inSync,

  /// Answered, but trails the most advanced guardian by more than the spread
  /// between healthy guardians explains.
  behind,

  /// Did not answer the latest round of requests, so nothing is known about
  /// where it is now.
  unknown,
}

/// What the guardians' sessions say about consensus as a whole.
class ConsensusSummary {
  const ConsensusSummary({required this.states, required this.tipAge});

  /// One per guardian, those in sync first and those that did not answer
  /// last, so the bar fills towards its threshold marker like the one for
  /// connectivity does.
  final List<GuardianSyncState> states;

  /// How long ago this wallet first saw the most advanced session. Null while
  /// no guardian has answered.
  final Duration? tipAge;

  int get inSync =>
      states.where((state) => state == GuardianSyncState.inSync).length;

  /// Whether the guardians, however well they agree, have stopped producing
  /// sessions.
  bool get isStalled {
    final tipAge = this.tipAge;
    return tipAge != null && tipAge >= consensusStalledAfter;
  }
}

ConsensusSummary summarizeConsensus(
  Iterable<GuardianSessionStatus?> guardians, {
  DateTime? now,
}) {
  final states = [
    for (final guardian in guardians)
      if (guardian == null || !guardian.fresh || guardian.sessionCount == null)
        GuardianSyncState.unknown
      else if (guardian.isBehind)
        GuardianSyncState.behind
      else
        GuardianSyncState.inSync,
  ]..sort((a, b) => a.index.compareTo(b.index));

  // The most advanced session, and the earliest any guardian was seen on it:
  // that is when the federation last moved, as far as this wallet can tell.
  BigInt? tip;
  BigInt? tipFirstSeenAt;
  for (final guardian in guardians) {
    final count = guardian?.sessionCount;
    final firstSeenAt = guardian?.firstSeenAt;
    if (guardian == null || !guardian.fresh) continue;
    if (count == null || firstSeenAt == null) continue;
    if (tip == null || count > tip) {
      tip = count;
      tipFirstSeenAt = firstSeenAt;
    } else if (count == tip && firstSeenAt < tipFirstSeenAt!) {
      tipFirstSeenAt = firstSeenAt;
    }
  }

  final Duration? tipAge;
  if (tipFirstSeenAt == null) {
    tipAge = null;
  } else {
    final age = (now ?? DateTime.now()).difference(
      _fromUnixSeconds(tipFirstSeenAt),
    );
    tipAge = age.isNegative ? Duration.zero : age;
  }

  return ConsensusSummary(states: states, tipAge: tipAge);
}

class FederationInfoScreen extends StatefulWidget {
  /// The federation to display. For joinable previews this can be null: the
  /// screen then downloads the metadata itself (from [inviteCode]) and shows a
  /// loading state, so the user is never stuck on a blocking spinner.
  final FederationSelector? fed;
  final String? welcomeMessage;
  final String? imageUrl;
  final VoidCallback onLeaveFederation;

  // Joinable mode fields
  final bool joinable;
  final String? inviteCode;
  final String? ecash;

  /// Name shown in the app bar while a joinable preview's metadata loads.
  final String? previewName;

  const FederationInfoScreen({
    super.key,
    this.fed,
    this.welcomeMessage,
    this.imageUrl,
    required this.onLeaveFederation,
    this.joinable = false,
    this.inviteCode,
    this.ecash,
    this.previewName,
  });

  @override
  State<FederationInfoScreen> createState() => _FederationInfoScreenState();
}

class _FederationInfoScreenState extends State<FederationInfoScreen> {
  double _animatedPercent = 0.0;
  StreamSubscription<List<PeerStatus>>? _peerUpdates;
  StreamSubscription<MultimintEvent>? _metaUpdates;
  StreamSubscription<List<GuardianSessionStatus>>? _sessionUpdates;
  List<PeerStatus>? _peers;

  /// Each guardian's consensus progress, by peer id. Replaced wholesale every
  /// time the guardians are asked again, which is also what keeps the ages on
  /// the rows current.
  Map<int, GuardianSessionStatus> _sessions = {};
  _InfoSection _selectedSection = _InfoSection.guardians;
  bool _isJoining = false;

  // Resolved federation data. Populated immediately from the widget when the
  // caller already has it, or after [_loadMeta] succeeds for a joinable preview.
  FederationSelector? _fed;
  String? _welcomeMessage;
  String? _imageUrl;

  /// Shutdown announcement the guardians published, if any, for the banner
  /// on a joinable preview.
  BigInt? _expiryTimestamp;
  String? _successorInvite;

  // Joinable preview loading state.
  bool _isLoadingMeta = false;
  Object? _loadError;

  @override
  void initState() {
    super.initState();

    if (widget.joinable && widget.fed == null) {
      // Preview: navigate in immediately and download the metadata here so the
      // user always has a back button while it loads (or fails).
      _loadMeta();
    } else {
      _fed = widget.fed;
      _welcomeMessage = widget.welcomeMessage;
      _imageUrl = widget.imageUrl;
      _subscribePeers();
      _subscribeSessions();
      _subscribeMetaUpdates();
      // A preview opened from a scanned or pasted invite arrives with the
      // federation already resolved and skips _loadMeta, so the shutdown
      // notice has to be read here or it is never shown.
      if (widget.joinable) _loadShutdownNotice();
    }
  }

  /// Reads the guardians' shutdown announcement for a joinable preview whose
  /// caller supplied the federation itself. Same cached meta the caller used.
  Future<void> _loadShutdownNotice() async {
    final inviteCode = widget.inviteCode;
    if (inviteCode == null) return;
    try {
      final meta = await getFederationMeta(inviteCode: inviteCode);
      if (!mounted) return;
      setState(() {
        _expiryTimestamp = meta.expiryTimestamp;
        _successorInvite = meta.successorInvite;
      });
    } catch (e) {
      AppLogger.instance.warn("Could not read federation meta: $e");
    }
  }

  @override
  void dispose() {
    _peerUpdates?.cancel();
    _metaUpdates?.cancel();
    _sessionUpdates?.cancel();
    super.dispose();
  }

  /// Reload the name, picture and welcome message when a guardian changes them
  /// through the meta module, so this screen updates while it is open.
  void _subscribeMetaUpdates() {
    _metaUpdates = subscribeMultimintEvents().listen((event) async {
      if (event is! MultimintEvent_MetaUpdated) return;
      final fed = _fed;
      if (fed == null || !mounted) return;

      final federationIdStr = await federationIdToString(
        federationId: fed.federationId,
      );
      if (event.field0 != federationIdStr || !mounted) return;

      try {
        final meta = await getFederationMeta(federationId: fed.federationId);
        if (!mounted) return;
        setState(() {
          _fed = meta.selector;
          _welcomeMessage = meta.welcome;
          _imageUrl = meta.picture;
          _expiryTimestamp = meta.expiryTimestamp;
          _successorInvite = meta.successorInvite;
        });
      } catch (e) {
        AppLogger.instance.warn("Could not reload federation meta: $e");
      }
    });
  }

  Future<void> _loadMeta() async {
    setState(() {
      _isLoadingMeta = true;
      _loadError = null;
    });
    try {
      final meta = await getFederationMeta(inviteCode: widget.inviteCode);
      if (!mounted) return;
      setState(() {
        _fed = meta.selector;
        _welcomeMessage = meta.welcome;
        _imageUrl = meta.picture;
        _expiryTimestamp = meta.expiryTimestamp;
        _successorInvite = meta.successorInvite;
        _isLoadingMeta = false;
      });
      _subscribePeers();
    } catch (e) {
      AppLogger.instance.warn("Error when retrieving federation meta: $e");
      if (!mounted) return;
      setState(() {
        _isLoadingMeta = false;
        _loadError = e;
      });
    }
  }

  void _subscribePeers() {
    final fed = _fed;
    if (fed == null) return;
    final stream = subscribePeerStatus(
      invite: widget.joinable ? widget.inviteCode : null,
      federationId: fed.federationId,
    );
    _peerUpdates = stream.listen((List<PeerStatus> event) {
      final onlineCount = event.where((p) => p.online).length;
      final totalCount = event.length;

      if (!mounted) return;
      setState(() {
        _peers = event;
        _animatedPercent = totalCount > 0 ? onlineCount / totalCount : 0.0;
      });
    });
  }

  /// Follows the guardians' session counts for as long as the screen is open.
  /// Joined federations only: the counts are persisted per federation, and a
  /// preview has no entry to persist them under.
  void _subscribeSessions() {
    final fed = _fed;
    if (fed == null || widget.joinable) return;
    _sessionUpdates = subscribeGuardianSessions(
      federationId: fed.federationId,
    ).listen(
      (List<GuardianSessionStatus> event) {
        if (!mounted) return;
        setState(() {
          _sessions = {for (final status in event) status.peerId: status};
        });
      },
      onError: (Object e) {
        AppLogger.instance.warn("Could not follow guardian sessions: $e");
      },
    );
  }

  // --- Leave federation logic ---

  Future<void> _onLeavePressed() => showLeaveFederationDialog(
    context,
    fed: _fed!,
    onLeaveFederation: widget.onLeaveFederation,
  );

  // --- Guardian dashboard login logic ---

  Future<void> _onGuardianTapped(PeerStatus peer) async {
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
                  federationId: _fed!.federationId,
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
                          fed: _fed!,
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

  // --- Join federation logic ---

  Future<void> _onJoinPressed(bool recover) async {
    setState(() {
      _isJoining = true;
    });

    try {
      final fed = await joinFederation(
        inviteCode: widget.inviteCode!,
        recover: recover,
      );
      AppLogger.instance.info('Successfully joined federation');

      // A federation that was left and re-joined keeps its NWC pairing, so the
      // listener has to be put back. Rust handles the desktop side inside
      // `joinFederation`; the Android listener lives in the foreground service
      // isolate, which only Dart can start.
      if (mounted) {
        await startNwcServiceIfPaired(context, fed);
      }

      try {
        backupInviteCodes();
      } catch (e) {
        AppLogger.instance.error("Could not backup Nostr invite codes: $e");
      }

      // A federation with a shutdown date takes no new Lightning Address
      // registrations. Decided from a fresh read of the joined federation's
      // meta rather than from preview state, which depends on how the preview
      // was opened and on whether its load had finished.
      if (!await _isShuttingDown(fed)) {
        await _claimLnAddress(fed);
      }

      if (widget.ecash != null) {
        _redeemEcash(widget.ecash!);
      }

      if (mounted) {
        Navigator.of(context).pop((fed, recover));
      }
    } catch (e) {
      AppLogger.instance.error('Could not join federation $e');
      if (mounted) {
        ToastService().show(
          message: context.l10n.couldNotJoinFederation,
          duration: const Duration(seconds: 5),
          onTap: () {},
          icon: Icon(Icons.error),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isJoining = false;
        });
      }
    }
  }

  /// Whether [fed]'s guardians have set a shutdown date, asked of them
  /// directly in one round trip rather than read from the cache, which can be
  /// weeks old for a federation previewed long before it was joined. When
  /// they cannot be asked this errs on the side of not claiming: an address
  /// registered on a federation that is closing is worse than one the user
  /// claims by hand.
  Future<bool> _isShuttingDown(FederationSelector fed) async {
    try {
      final expiry = await fetchFederationExpiry(
        federationId: fed.federationId,
      );
      return expiry != null;
    } catch (e) {
      AppLogger.instance.warn(
        "Could not ask the federation for its expiry: $e",
      );
      return true;
    }
  }

  Future<void> _claimLnAddress(FederationSelector fed) async {
    String defaultLnAddress = "https://ecash.love";
    String defaultRecurringd = "https://recurring.ecash.love";
    try {
      await claimRandomLnAddress(
        federationId: fed.federationId,
        lnAddressApi: defaultLnAddress,
        recurringdApi: defaultRecurringd,
      );
    } catch (e) {
      AppLogger.instance.error("Could not claim random LN Address: $e");
    }
  }

  Future<void> _redeemEcash(String ecash) async {
    try {
      final isSpent = await checkEcashSpent(
        federationId: _fed!.federationId,
        ecash: ecash,
      );

      if (isSpent) {
        if (mounted) {
          ToastService().show(
            message: context.l10n.ecashAlreadyClaimed,
            duration: const Duration(seconds: 5),
            onTap: () {},
            icon: Icon(Icons.error),
          );
        }
        return;
      }

      final fees = await calculateEcashReissueFees(
        federationId: _fed!.federationId,
        ecash: ecash,
      );

      await reissueEcash(
        federationId: _fed!.federationId,
        ecash: ecash,
        fees: fees,
      );
    } catch (e) {
      AppLogger.instance.error("Could not reissue Ecash $e");
      if (mounted) {
        ToastService().show(
          message: context.l10n.couldNotClaimEcash,
          duration: const Duration(seconds: 5),
          onTap: () {},
          icon: Icon(Icons.error),
        );
      }
    }
  }

  // --- UI building methods ---

  Widget _buildHealthStatusBar({
    required ThemeData theme,
    required int onlineCount,
    required int totalCount,
    required int threshold,
  }) {
    if (totalCount == 0) return const SizedBox.shrink();

    final percentOnline = totalCount > 0 ? onlineCount / totalCount : 0.0;
    Color borderColor;

    if (percentOnline >= 1.0) {
      borderColor = Colors.green;
    } else if (onlineCount >= threshold) {
      borderColor = Colors.amber;
    } else {
      borderColor = Colors.red;
    }

    return _buildThresholdBar(
      theme: theme,
      label: context.l10n.connectedToGuardians(onlineCount, totalCount),
      color: borderColor,
      totalCount: totalCount,
      threshold: threshold,
      fill: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.0, end: _animatedPercent),
        duration: const Duration(milliseconds: 800),
        builder: (context, value, _) {
          return LinearProgressIndicator(
            value: value,
            minHeight: 10,
            backgroundColor: theme.colorScheme.surfaceContainerHighest
                .withValues(alpha: 0.3),
            valueColor: AlwaysStoppedAnimation<Color>(borderColor),
          );
        },
      ),
    );
  }

  /// Whether the guardians are working together, as a twin of the bar above:
  /// one segment per guardian, and the same marker for how many of them
  /// consensus needs.
  ///
  /// Agreement alone would not do. A federation whose guardians all sit on the
  /// same session while producing no new ones agrees perfectly, so once the
  /// most advanced session has gone [consensusStalledAfter] without a
  /// successor the bar reports that instead, whatever the guardians agree on.
  Widget _buildConsensusBar({
    required ThemeData theme,
    required int threshold,
  }) {
    final peers = _peers;
    if (peers == null || peers.isEmpty || _sessions.isEmpty) {
      return const SizedBox.shrink();
    }

    final l10n = context.l10n;
    final summary = summarizeConsensus(
      peers.map((peer) => _sessions[peer.peerId]),
    );
    final tipAge = summary.tipAge;

    final Color color;
    final String label;
    if (tipAge == null) {
      color = Colors.grey;
      label = l10n.consensusWaiting;
    } else if (summary.isStalled) {
      color = Colors.red;
      label = l10n.consensusStalled(_formatLongDuration(l10n, tipAge));
    } else {
      color =
          summary.inSync == peers.length
              ? Colors.green
              : summary.inSync >= threshold
              ? Colors.amber
              : Colors.red;
      label = l10n.consensusInSync(
        summary.inSync,
        peers.length,
        formatSessionAge(l10n, tipAge),
      );
    }

    // The segments keep their own colours rather than taking the bar's, or a
    // guardian that is behind would look the same as the ones keeping up.
    Color segmentColor(GuardianSyncState state) => switch (state) {
      GuardianSyncState.inSync => summary.isStalled ? Colors.red : Colors.green,
      GuardianSyncState.behind => Colors.amber,
      GuardianSyncState.unknown => theme.colorScheme.surfaceContainerHighest
          .withValues(alpha: 0.3),
    };

    // The lock under the bar above hangs below its own box, so the gap has to
    // clear it.
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: _buildThresholdBar(
        theme: theme,
        label: label,
        color: color,
        totalCount: peers.length,
        threshold: threshold,
        fill: _consensusSegments(summary, segmentColor),
      ),
    );
  }

  Widget _consensusSegments(
    ConsensusSummary summary,
    Color Function(GuardianSyncState) segmentColor,
  ) {
    return SizedBox(
      height: 10,
      child: Row(
        children: [
          for (final (index, state) in summary.states.indexed)
            Expanded(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 400),
                margin: EdgeInsets.only(left: index == 0 ? 0 : 2),
                color: segmentColor(state),
              ),
            ),
        ],
      ),
    );
  }

  /// The frame the guardian bars share: a label, a bordered bar around [fill],
  /// and a marker with a lock under it at the share of guardians that make up
  /// the threshold.
  Widget _buildThresholdBar({
    required ThemeData theme,
    required String label,
    required Color color,
    required int totalCount,
    required int threshold,
    required Widget fill,
  }) {
    final borderColor = color;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          label,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(color: borderColor),
        ),
        const SizedBox(height: 4),
        LayoutBuilder(
          builder: (context, constraints) {
            final barWidth = constraints.maxWidth;
            final thresholdPos =
                totalCount > 0 ? (threshold / totalCount) * barWidth : 0.0;

            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: borderColor, width: 1.5),
                  ),
                  child: Stack(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: fill,
                      ),
                      Positioned(
                        left: (thresholdPos - 5).clamp(0.0, barWidth - 4),
                        top: 0,
                        bottom: 0,
                        child: Container(
                          width: 4,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(2),
                            boxShadow: const [
                              BoxShadow(
                                color: Colors.black26,
                                blurRadius: 3,
                                spreadRadius: 1,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  height: 18,
                  child: Stack(
                    children: [
                      Positioned(
                        left: (thresholdPos - 10).clamp(0.0, barWidth - 12),
                        top: 8,
                        bottom: 0,
                        child: Icon(Icons.lock, size: 24, color: borderColor),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _buildSectionChips(ThemeData theme) {
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 8,
      runSpacing: 8,
      children: [
        _buildChip(
          theme: theme,
          label: context.l10n.guardianTab,
          icon: Icons.shield_outlined,
          section: _InfoSection.guardians,
        ),
        _buildChip(
          theme: theme,
          label: context.l10n.utxoTab,
          icon: Icons.account_balance_outlined,
          section: _InfoSection.utxos,
        ),
        _buildChip(
          theme: theme,
          label: context.l10n.gateways,
          icon: Icons.device_hub,
          section: _InfoSection.gateways,
        ),
      ],
    );
  }

  Widget _buildChip({
    required ThemeData theme,
    required String label,
    required IconData icon,
    required _InfoSection section,
  }) {
    final isSelected = _selectedSection == section;
    return FilterChip(
      selected: isSelected,
      label: Text(label),
      avatar: Icon(
        icon,
        size: 18,
        color: isSelected ? theme.colorScheme.onPrimary : Colors.grey,
      ),
      selectedColor: theme.colorScheme.primary,
      backgroundColor: theme.colorScheme.surface,
      labelStyle: TextStyle(
        color: isSelected ? theme.colorScheme.onPrimary : Colors.grey,
        fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
      ),
      side: BorderSide(
        color:
            isSelected
                ? theme.colorScheme.primary
                : Colors.grey.withValues(alpha: 0.3),
      ),
      showCheckmark: false,
      onSelected: (_) {
        setState(() {
          _selectedSection = section;
        });
      },
    );
  }

  Widget _buildGuardianList(bool isFederationOnline) {
    if (_peers == null || _peers!.isEmpty) {
      return Center(child: Text(context.l10n.loading));
    }

    return ListView.builder(
      padding: const EdgeInsets.only(top: 8),
      itemCount: _peers!.length,
      itemBuilder: (context, index) {
        final peer = _peers![index];
        final isOnline = peer.online;

        final theme = Theme.of(context);
        final sessionColumn = _sessionColumn(theme, _sessions[peer.peerId]);
        return ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          onTap:
              !widget.joinable && isOnline
                  ? () => _onGuardianTapped(peer)
                  : null,
          leading: Icon(
            Icons.circle,
            color: isOnline ? Colors.green : Colors.red,
            size: 12,
          ),
          title: Row(
            children: [
              Expanded(child: Text(peer.name, overflow: TextOverflow.ellipsis)),
              if (isOnline) _connectivityBadge(theme, peer.connectivity),
              // Centred in what is left of the row, which puts it halfway
              // between the badge and the invite code buttons.
              if (isOnline || sessionColumn != null)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Center(child: sessionColumn),
                  ),
                ),
            ],
          ),
          subtitle:
              isOnline
                  ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.l10n.versionLabel(peer.version ?? ''),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.grey,
                        ),
                      ),
                      Text(
                        peer.url,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.grey,
                        ),
                      ),
                    ],
                  )
                  : Text(context.l10n.disconnected),
          trailing:
              !widget.joinable && isFederationOnline
                  ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: context.l10n.copyInviteCode,
                        icon: const Icon(Icons.copy, size: 20),
                        onPressed: () async {
                          try {
                            final inviteCode = await getInviteCode(
                              federationId: _fed!.federationId,
                              peer: peer.peerId,
                            );
                            if (!context.mounted) return;
                            await Clipboard.setData(
                              ClipboardData(text: inviteCode),
                            );
                            ToastService().show(
                              message: context.l10n.inviteCodeCopied(peer.name),
                              duration: const Duration(seconds: 5),
                              onTap: () {},
                              icon: Icon(Icons.check),
                            );
                          } catch (e) {
                            AppLogger.instance.error(
                              "Error getting invite code: $e",
                            );
                            ToastService().show(
                              message: context.l10n.couldNotGetInviteCode,
                              duration: const Duration(seconds: 5),
                              onTap: () {},
                              icon: Icon(Icons.error),
                            );
                          }
                        },
                      ),
                      IconButton(
                        tooltip: context.l10n.viewInviteCode,
                        icon: const Icon(Icons.qr_code, size: 20),
                        onPressed: () async {
                          try {
                            final inviteCode = await getInviteCode(
                              federationId: _fed!.federationId,
                              peer: peer.peerId,
                            );
                            if (!context.mounted) return;
                            showDialog(
                              context: context,
                              builder:
                                  (context) => AlertDialog(
                                    title: Center(
                                      child: Text(
                                        context.l10n.inviteCode,
                                        textAlign: TextAlign.center,
                                      ),
                                    ),
                                    content: AspectRatio(
                                      aspectRatio: 1,
                                      child: GestureDetector(
                                        onTap: () {
                                          showDialog(
                                            context: context,
                                            builder:
                                                (_) => Dialog(
                                                  backgroundColor:
                                                      Colors.transparent,
                                                  insetPadding: EdgeInsets.zero,
                                                  child: GestureDetector(
                                                    onTap:
                                                        () =>
                                                            Navigator.of(
                                                              context,
                                                              rootNavigator:
                                                                  true,
                                                            ).pop(),
                                                    child: Container(
                                                      width: double.infinity,
                                                      height: double.infinity,
                                                      color: Colors.black
                                                          .withValues(
                                                            alpha: 0.9,
                                                          ),
                                                      child: Center(
                                                        child: QrImageView(
                                                          data: inviteCode,
                                                          version:
                                                              QrVersions.auto,
                                                          backgroundColor:
                                                              Colors.white,
                                                          size:
                                                              MediaQuery.of(
                                                                context,
                                                              ).size.width *
                                                              0.9,
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                          );
                                        },
                                        child: QrImageView(
                                          data: inviteCode,
                                          version: QrVersions.auto,
                                          backgroundColor: Colors.white,
                                        ),
                                      ),
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed:
                                            () => Navigator.of(context).pop(),
                                        child: Text(context.l10n.close),
                                      ),
                                    ],
                                  ),
                            );
                          } catch (e) {
                            AppLogger.instance.error(
                              "Error getting invite code: $e",
                            );
                            ToastService().show(
                              message: context.l10n.couldNotGetInviteCode,
                              duration: const Duration(seconds: 5),
                              onTap: () {},
                              icon: Icon(Icons.error),
                            );
                          }
                        },
                      ),
                    ],
                  )
                  : null,
        );
      },
    );
  }

  Widget _buildSelectedContent(bool isFederationOnline) {
    switch (_selectedSection) {
      case _InfoSection.guardians:
        return _buildGuardianList(isFederationOnline);
      case _InfoSection.utxos:
        return FederationUtxoList(
          invite: widget.joinable ? widget.inviteCode : null,
          fed: _fed!,
          isFederationOnline: isFederationOnline,
        );
      case _InfoSection.gateways:
        return GatewaysList(
          fed: _fed!,
          invite: widget.joinable ? widget.inviteCode : null,
        );
    }
  }

  Widget _buildJoinButtons(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ElevatedButton(
            onPressed: _isJoining ? null : () => _onJoinPressed(false),
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
            child:
                _isJoining
                    ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                        color: Colors.black,
                        strokeWidth: 2,
                      ),
                    )
                    : widget.ecash == null
                    ? Text(context.l10n.joinFederation)
                    : Text(context.l10n.joinAndRedeemEcash),
          ),
        ],
      ),
    );
  }

  /// Shown for a joinable preview while its metadata downloads, or if the
  /// download fails. Always has a back button (the app bar), so the user can
  /// cancel instead of being stuck on a spinner, plus a Retry on failure.
  Widget _buildLoadingOrError(ThemeData theme) {
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Text(widget.previewName ?? context.l10n.loading),
      ),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child:
                _loadError != null
                    ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.cloud_off,
                          size: 48,
                          color: Colors.grey,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          context.l10n.couldNotGetFederationMetadata,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: Colors.grey,
                          ),
                        ),
                        const SizedBox(height: 24),
                        ElevatedButton.icon(
                          onPressed: _isLoadingMeta ? null : _loadMeta,
                          icon: const Icon(Icons.refresh),
                          label: Text(context.l10n.retry),
                        ),
                      ],
                    )
                    : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 16),
                        Text(
                          context.l10n.loading,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: Colors.grey,
                          ),
                        ),
                      ],
                    ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Joinable preview whose metadata hasn't resolved yet (still loading or
    // failed): show a cancellable loading/error screen instead of the content.
    if (_fed == null) {
      return _buildLoadingOrError(theme);
    }

    final totalGuardians = _peers?.length ?? 0;
    final thresh = threshold(totalGuardians);
    final onlineGuardians = _peers?.where((p) => p.online).toList() ?? [];
    final isFederationOnline =
        totalGuardians > 0 && onlineGuardians.length >= thresh;

    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Text(_fed!.federationName),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) {
              if (value == 'leave') {
                _onLeavePressed();
              } else if (value == 'recover') {
                _onJoinPressed(true);
              }
            },
            itemBuilder:
                (context) => [
                  if (widget.joinable)
                    PopupMenuItem(
                      value: 'recover',
                      enabled: !_isJoining,
                      child: Row(
                        children: [
                          const Icon(Icons.history, size: 20),
                          const SizedBox(width: 12),
                          Text(context.l10n.recover),
                        ],
                      ),
                    ),
                  if (!widget.joinable)
                    PopupMenuItem(
                      value: 'leave',
                      child: Row(
                        children: [
                          const Icon(Icons.logout, color: Colors.red, size: 20),
                          const SizedBox(width: 12),
                          Text(
                            context.l10n.leaveFederation,
                            style: const TextStyle(color: Colors.red),
                          ),
                        ],
                      ),
                    ),
                ],
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Federation image, welcome message, health bar, chips
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Column(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: SizedBox(
                      width: 80,
                      height: 80,
                      child:
                          _imageUrl != null
                              ? Image.network(
                                _imageUrl!,
                                fit: BoxFit.cover,
                                errorBuilder: (context, error, stackTrace) {
                                  return Image.asset(
                                    'assets/images/fedimint-icon-color.png',
                                    fit: BoxFit.cover,
                                  );
                                },
                              )
                              : Image.asset(
                                'assets/images/fedimint-icon-color.png',
                                fit: BoxFit.cover,
                              ),
                    ),
                  ),
                  // Someone about to join should see this before anything
                  // else. Joining stays possible: they may hold funds here
                  // that they need to recover or move out.
                  if (widget.joinable &&
                      (_expiryTimestamp != null || _successorInvite != null))
                    FederationExpiryBanner(
                      expiryTimestamp: _expiryTimestamp,
                      onTap: null,
                      compact: false,
                      note:
                          _expiryTimestamp != null
                              ? context.l10n.federationExpiryBannerJoinHint
                              : context
                                  .l10n
                                  .federationExpiryBannerSuccessorJoinHint,
                    ),
                  if (_welcomeMessage != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _welcomeMessage!,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: Colors.grey,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                  if (_fed!.network != null &&
                      _fed!.network!.toLowerCase() != 'bitcoin') ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.orange.shade100,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.warning, color: Colors.orange),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              context.l10n.testNetworkWarning(
                                _fed!.network ?? '',
                              ),
                              style: const TextStyle(color: Colors.orange),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  _buildHealthStatusBar(
                    theme: theme,
                    onlineCount: onlineGuardians.length,
                    totalCount: totalGuardians,
                    threshold: thresh,
                  ),
                  _buildConsensusBar(theme: theme, threshold: thresh),
                  const SizedBox(height: 16),
                  _buildSectionChips(theme),
                  const SizedBox(height: 8),
                ],
              ),
            ),
            // Content area
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: _buildSelectedContent(isFederationOnline),
              ),
            ),
            // Join buttons at bottom when joinable
            if (widget.joinable) _buildJoinButtons(theme),
          ],
        ),
      ),
    );
  }

  /// A guardian's session count with its age underneath, or null while the
  /// guardian has never answered.
  ///
  /// The column is narrow on a phone. The count is left to wrap there, which
  /// puts the number under the word; the age shrinks instead, since half an
  /// age is worse than a small one.
  Widget? _sessionColumn(ThemeData theme, GuardianSessionStatus? session) {
    final l10n = context.l10n;
    final count = formatGuardianSessionCount(l10n, session);
    final age = formatGuardianSessionAge(l10n, session);
    if (session == null || count == null || age == null) return null;

    // Faded until the guardian has answered this round: what is on disk says
    // where it was, not where it is.
    final alpha = session.fresh ? 1.0 : 0.5;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          count,
          maxLines: 2,
          textAlign: TextAlign.center,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: alpha),
            fontWeight: FontWeight.w600,
          ),
        ),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            age,
            maxLines: 1,
            softWrap: false,
            style: theme.textTheme.bodySmall?.copyWith(
              color: Colors.grey.withValues(alpha: alpha),
            ),
          ),
        ),
      ],
    );
  }

  Widget _connectivityBadge(ThemeData theme, PeerConnectivity c) {
    final color = switch (c) {
      PeerConnectivity.direct => Colors.green,
      PeerConnectivity.relay => Colors.amber,
      PeerConnectivity.mixed => Colors.teal,
      PeerConnectivity.tor => Colors.deepPurple,
      PeerConnectivity.unknown => Colors.grey,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.5), width: 1),
      ),
      child: Text(
        _connectivityLabel(context, c),
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  String _connectivityLabel(BuildContext context, PeerConnectivity c) {
    switch (c) {
      case PeerConnectivity.direct:
        return context.l10n.connectionDirect;
      case PeerConnectivity.relay:
        return context.l10n.connectionRelay;
      case PeerConnectivity.mixed:
        return context.l10n.connectionMixed;
      case PeerConnectivity.tor:
        return context.l10n.connectionTor;
      case PeerConnectivity.unknown:
        return context.l10n.connectionUnknown;
    }
  }
}
