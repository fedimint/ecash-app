import 'dart:async';

import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/widgets/federation_utxo_list.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/toast.dart';
import 'package:ecashapp/utils.dart';
import 'package:ecashapp/widgets/gateways.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

enum _InfoSection { guardians, utxos, gateways }

class FederationInfoScreen extends StatefulWidget {
  final FederationSelector fed;
  final String? welcomeMessage;
  final String? imageUrl;
  final List<Guardian>? guardians;
  final VoidCallback onLeaveFederation;

  // Joinable mode fields
  final bool joinable;
  final String? inviteCode;
  final String? ecash;

  const FederationInfoScreen({
    super.key,
    required this.fed,
    this.welcomeMessage,
    this.imageUrl,
    this.guardians,
    required this.onLeaveFederation,
    this.joinable = false,
    this.inviteCode,
    this.ecash,
  });

  @override
  State<FederationInfoScreen> createState() => _FederationInfoScreenState();
}

class _FederationInfoScreenState extends State<FederationInfoScreen> {
  double _animatedPercent = 0.0;
  late StreamSubscription<List<PeerStatus>> _peerUpdates;
  List<PeerStatus>? _peers;
  _InfoSection _selectedSection = _InfoSection.guardians;
  bool _isJoining = false;

  @override
  void initState() {
    super.initState();

    Stream<List<PeerStatus>> stream = subscribePeerStatus(
      invite: widget.joinable ? widget.inviteCode : null,
      federationId: widget.fed.federationId,
    );
    _peerUpdates = stream.listen((List<PeerStatus> event) {
      final onlineCount = event.where((p) => p.online).length;
      final totalCount = event.length;

      setState(() {
        _peers = event;
        _animatedPercent = totalCount > 0 ? onlineCount / totalCount : 0.0;
      });
    });
  }

  @override
  void dispose() {
    _peerUpdates.cancel();
    super.dispose();
  }

  // --- Leave federation logic ---

  Future<void> _onLeavePressed() async {
    final screenNavigator = Navigator.of(context);

    await showDialog(
      context: context,
      builder: (dialogContext) {
        bool isLeaving = false;

        return StatefulBuilder(
          builder: (sbContext, setState) {
            return AlertDialog(
              title: Text(sbContext.l10n.leaveFederation),
              content: Text(sbContext.l10n.leaveFederationConfirm),
              actions: [
                TextButton(
                  onPressed:
                      isLeaving
                          ? null
                          : () => Navigator.of(dialogContext).pop(),
                  child: Text(sbContext.l10n.cancel),
                ),
                TextButton(
                  onPressed:
                      isLeaving
                          ? null
                          : () async {
                            setState(() {
                              isLeaving = true;
                            });

                            try {
                              await leaveFederation(
                                federationId: widget.fed.federationId,
                              );
                              try {
                                backupInviteCodes();
                              } catch (e) {
                                AppLogger.instance.error(
                                  "Could not backup Nostr invite codes: $e",
                                );
                              }
                              widget.onLeaveFederation();

                              if (dialogContext.mounted) {
                                Navigator.of(dialogContext).pop();
                              }
                              screenNavigator.popUntil(
                                (route) => route.isFirst,
                              );
                            } catch (e) {
                              AppLogger.instance.error(
                                "Error leaving federation: $e",
                              );
                              if (dialogContext.mounted) {
                                Navigator.of(dialogContext).pop();
                              }
                              screenNavigator.popUntil(
                                (route) => route.isFirst,
                              );
                            } finally {
                              if (mounted) {
                                setState(() {
                                  isLeaving = false;
                                });
                              }
                            }
                          },
                  child:
                      isLeaving
                          ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                          : Text(sbContext.l10n.confirm),
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

      try {
        backupInviteCodes();
      } catch (e) {
        AppLogger.instance.error("Could not backup Nostr invite codes: $e");
      }

      await _claimLnAddress(fed);

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
        federationId: widget.fed.federationId,
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
        federationId: widget.fed.federationId,
        ecash: ecash,
      );

      await reissueEcash(
        federationId: widget.fed.federationId,
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          context.l10n.connectedToGuardians(onlineCount, totalCount),
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
                        child: TweenAnimationBuilder<double>(
                          tween: Tween(begin: 0.0, end: _animatedPercent),
                          duration: const Duration(milliseconds: 800),
                          builder: (context, value, _) {
                            return LinearProgressIndicator(
                              value: value,
                              minHeight: 10,
                              backgroundColor: theme
                                  .colorScheme
                                  .surfaceContainerHighest
                                  .withValues(alpha: 0.3),
                              valueColor: AlwaysStoppedAnimation<Color>(
                                borderColor,
                              ),
                            );
                          },
                        ),
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
        return ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            Icons.circle,
            color: isOnline ? Colors.green : Colors.red,
            size: 12,
          ),
          title: Text(peer.name),
          subtitle:
              isOnline
                  ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.l10n.versionLabel(
                          widget.guardians?[index].version ?? '',
                        ),
                      ),
                      Text(
                        '${_connectivityLabel(context, peer.connectivity)} · ${_truncateUrl(peer.url)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.grey,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
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
                              federationId: widget.fed.federationId,
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
                              federationId: widget.fed.federationId,
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
          fed: widget.fed,
          isFederationOnline: isFederationOnline,
        );
      case _InfoSection.gateways:
        return GatewaysList(
          fed: widget.fed,
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final totalGuardians = _peers?.length ?? 0;
    final thresh = threshold(totalGuardians);
    final onlineGuardians = _peers?.where((p) => p.online).toList() ?? [];
    final isFederationOnline =
        totalGuardians > 0 && onlineGuardians.length >= thresh;

    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Text(widget.fed.federationName),
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
                          widget.imageUrl != null
                              ? Image.network(
                                widget.imageUrl!,
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
                  if (widget.welcomeMessage != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      widget.welcomeMessage!,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: Colors.grey,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                  if (widget.fed.network != null &&
                      widget.fed.network!.toLowerCase() != 'bitcoin') ...[
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
                                widget.fed.network ?? '',
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

  // iroh URLs embed a 64-char hex node id that blows out the subtitle line on
  // mobile; collapse the middle for long URLs. wss/http URLs are usually short
  // enough to show in full.
  String _truncateUrl(String url) {
    const maxLen = 32;
    if (url.length <= maxLen) return url;
    final schemeEnd = url.indexOf('://');
    if (schemeEnd < 0) {
      return '${url.substring(0, 6)}…${url.substring(url.length - 6)}';
    }
    final prefix = url.substring(0, schemeEnd + 3);
    final rest = url.substring(schemeEnd + 3);
    if (rest.length <= 10) return url;
    return '$prefix${rest.substring(0, 4)}…${rest.substring(rest.length - 4)}';
  }
}
