import 'dart:async';

import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/fed_preview.dart';
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

  const FederationInfoScreen({
    super.key,
    required this.fed,
    this.welcomeMessage,
    this.imageUrl,
    this.guardians,
    required this.onLeaveFederation,
  });

  @override
  State<FederationInfoScreen> createState() => _FederationInfoScreenState();
}

class _FederationInfoScreenState extends State<FederationInfoScreen> {
  double _animatedPercent = 0.0;
  late StreamSubscription<List<PeerStatus>> _peerUpdates;
  List<PeerStatus>? _peers;
  _InfoSection _selectedSection = _InfoSection.guardians;

  @override
  void initState() {
    super.initState();

    Stream<List<PeerStatus>> stream = subscribePeerStatus(
      invite: null,
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
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _buildChip(
          theme: theme,
          label: context.l10n.guardianTab,
          icon: Icons.shield_outlined,
          section: _InfoSection.guardians,
        ),
        const SizedBox(width: 8),
        _buildChip(
          theme: theme,
          label: context.l10n.utxoTab,
          icon: Icons.account_balance_outlined,
          section: _InfoSection.utxos,
        ),
        const SizedBox(width: 8),
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
                  ? Text(
                    context.l10n.versionLabel(
                      widget.guardians?[index].version ?? '',
                    ),
                  )
                  : Text(context.l10n.disconnected),
          trailing:
              isFederationOnline
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
          invite: null,
          fed: widget.fed,
          isFederationOnline: isFederationOnline,
        );
      case _InfoSection.gateways:
        return GatewaysList(fed: widget.fed);
    }
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
              }
            },
            itemBuilder:
                (context) => [
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
            // Federation image and welcome message
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
          ],
        ),
      ),
    );
  }
}
