import 'dart:async';

import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/screens/guardian_screen.dart';
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

enum _InfoSection { guardians, utxos, gateways }

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

  /// Notifiers rather than plain fields so an open [GuardianScreen] follows
  /// the same updates as this screen.
  final ValueNotifier<List<PeerStatus>?> _peers = ValueNotifier(null);

  /// Each guardian's consensus progress, by peer id. Replaced wholesale every
  /// time the guardians are asked again, which is also what keeps the ages on
  /// the rows current.
  final ValueNotifier<Map<int, GuardianSessionStatus>> _sessions =
      ValueNotifier(const {});
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
    _peers.dispose();
    _sessions.dispose();
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
      _subscribeSessions();
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
        _peers.value = event;
        _animatedPercent = totalCount > 0 ? onlineCount / totalCount : 0.0;
      });
    });
  }

  /// Follows the guardians' session counts for as long as the screen is open.
  void _subscribeSessions() {
    final fed = _fed;
    if (fed == null) return;
    _sessionUpdates = subscribeGuardianSessions(
      invite: widget.joinable ? widget.inviteCode : null,
      federationId: fed.federationId,
    ).listen(
      (List<GuardianSessionStatus> event) {
        if (!mounted) return;
        setState(() {
          _sessions.value = {for (final status in event) status.peerId: status};
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

  /// A label, a bordered bar around [fill], and a marker with a lock under it
  /// at the share of guardians that make up the threshold.
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

  Widget _buildGuardianList() {
    final peers = _peers.value;
    if (peers == null || peers.isEmpty) {
      return Center(child: Text(context.l10n.loading));
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: peers.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) => _buildGuardianRow(peers[index]),
    );
  }

  /// One guardian at a glance: whether it can be reached (the dot on the
  /// avatar), its place in consensus (the pill), and the session it last
  /// reported. Everything else is on the [GuardianScreen] it opens.
  Widget _buildGuardianRow(PeerStatus peer) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final session = _sessions.value[peer.peerId];
    final state = guardianSyncState(online: peer.online, session: session);
    final count = formatGuardianSessionCount(l10n, session);
    final age = formatGuardianSessionAge(l10n, session);
    // Faded until the guardian has answered this round: what is on disk says
    // where it was, not where it is.
    final alpha = session?.fresh == true ? 1.0 : 0.5;

    return Material(
      color: const Color(0xFF1A1A1A),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openGuardian(peer),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              GuardianAvatar(name: peer.name, online: peer.online),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      peer.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (count != null && age != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        '$count · $age', // i18n-ignore
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.grey.withValues(alpha: alpha),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              GuardianPill.sync(l10n, theme, state),
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right, color: Colors.grey),
            ],
          ),
        ),
      ),
    );
  }

  void _openGuardian(PeerStatus peer) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder:
            (_) => GuardianScreen(
              fed: _fed!,
              peer: peer,
              peers: _peers,
              sessions: _sessions,
              joinable: widget.joinable,
            ),
      ),
    );
  }

  Widget _buildSelectedContent(bool isFederationOnline) {
    switch (_selectedSection) {
      case _InfoSection.guardians:
        return _buildGuardianList();
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

    final totalGuardians = _peers.value?.length ?? 0;
    final thresh = threshold(totalGuardians);
    final onlineGuardians = _peers.value?.where((p) => p.online).toList() ?? [];
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
}
