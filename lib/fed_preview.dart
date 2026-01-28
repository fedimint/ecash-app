import 'dart:async';

import 'package:ecashapp/db.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/providers/preferences_provider.dart';
import 'package:ecashapp/toast.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

class FederationPreview extends StatefulWidget {
  final FederationSelector fed;
  final String? inviteCode;
  final String? welcomeMessage;
  final String? imageUrl;
  final bool joinable;
  final List<Guardian>? guardians;
  final VoidCallback? onLeaveFederation;
  final String? ecash;

  const FederationPreview({
    super.key,
    required this.fed,
    this.inviteCode,
    this.welcomeMessage,
    this.imageUrl,
    required this.joinable,
    this.guardians,
    this.onLeaveFederation,
    this.ecash,
  });

  @override
  State<FederationPreview> createState() => _FederationPreviewState();
}

class _FederationPreviewState extends State<FederationPreview> {
  bool isJoining = false;
  bool _showAdvanced = false;
  double _animatedPercent = 0.0;
  late StreamSubscription<List<PeerStatus>> _peerUpdates;
  List<PeerStatus>? _peers;

  @override
  void initState() {
    super.initState();

    Stream<List<PeerStatus>> stream = subscribePeerStatus(
      invite: widget.inviteCode,
      federationId: widget.fed.federationId,
    );
    _peerUpdates = stream.listen((List<PeerStatus> event) async {
      setState(() {
        _peers = event;
      });

      final onlineCount = _peers!.where((p) => p.online).length;
      final totalCount = _peers!.length;

      setState(() {
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
    final bottomSheetContext = context;
    await showDialog(
      context: context,
      builder: (dialogContext) {
        bool isLeaving = false;

        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text("Leave Federation"),
              content: const Text(
                "Are you sure you want to leave this federation? You will need to re-join this federation to access any remaining funds.",
              ),
              actions: [
                TextButton(
                  onPressed:
                      isLeaving ? null : () => Navigator.of(context).pop(),
                  child: const Text("Cancel"),
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
                              await _backupToNostr();
                              widget.onLeaveFederation!();

                              if (context.mounted) {
                                Navigator.of(
                                  dialogContext,
                                ).popUntil((route) => route.isFirst);
                                Navigator.of(
                                  bottomSheetContext,
                                ).popUntil((route) => route.isFirst);
                                Navigator.of(
                                  context,
                                ).popUntil((route) => route.isFirst);
                              }
                            } catch (e) {
                              AppLogger.instance.error(
                                "Error leaving federation: $e",
                              );
                              if (context.mounted) {
                                Navigator.of(
                                  dialogContext,
                                ).popUntil((route) => route.isFirst);
                                Navigator.of(
                                  bottomSheetContext,
                                ).popUntil((route) => route.isFirst);
                                Navigator.of(
                                  context,
                                ).popUntil((route) => route.isFirst);
                              }
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
                          : const Text("Confirm"),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _backupToNostr() async {
    try {
      // backup the federation's invite codes as a replaceable event to Nostr
      backupInviteCodes();
    } catch (e) {
      AppLogger.instance.error("Could not backup Nostr invite codes: $e");
    }
  }

  Future<void> _claimLnAddress(FederationSelector fed) async {
    String defaultLnAddress = "https://ecash.love";
    String defaultRecurringd = "https://lnurl.ecash.love";
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

  Future<void> _onJoinPressed(bool recover) async {
    if (widget.joinable) {
      setState(() {
        isJoining = true;
      });

      try {
        final fed = await joinFederation(
          inviteCode: widget.inviteCode!,
          recover: recover,
        );
        AppLogger.instance.info('Successfully joined federation');

        _backupToNostr();
        await _claimLnAddress(fed);

        if (widget.ecash != null) {
          _redeemEcash(widget.ecash!);
        }

        if (mounted) {
          Navigator.of(context).pop((fed, false));
        }
      } catch (e) {
        AppLogger.instance.error('Could not join federation $e');
        ToastService().show(
          message: "Could not join federation",
          duration: const Duration(seconds: 5),
          onTap: () {},
          icon: Icon(Icons.error),
        );
      } finally {
        setState(() {
          isJoining = false;
        });
      }
    }
  }

  Future<void> _redeemEcash(String ecash) async {
    try {
      final isSpent = await checkEcashSpent(
        federationId: widget.fed.federationId,
        ecash: ecash,
      );

      if (isSpent) {
        ToastService().show(
          message: "This Ecash has already been claimed",
          duration: const Duration(seconds: 5),
          onTap: () {},
          icon: Icon(Icons.error),
        );
        return;
      }

      await reissueEcash(federationId: widget.fed.federationId, ecash: ecash);
    } catch (e) {
      AppLogger.instance.error("Could not reissue Ecash $e");
      ToastService().show(
        message: "Could not claim Ecash",
        duration: const Duration(seconds: 5),
        onTap: () {},
        icon: Icon(Icons.error),
      );
    }
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
          "$onlineCount / $totalCount Guardians Online",
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
                                  .withOpacity(0.3),
                              valueColor: AlwaysStoppedAnimation<Color>(
                                borderColor,
                              ),
                            );
                          },
                        ),
                      ),

                      // Threshold Marker Line
                      Positioned(
                        left: (thresholdPos - 5).clamp(0.0, barWidth - 4),
                        top: 0,
                        bottom: 0,
                        child: Container(
                          width: 4,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(2),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black26,
                                blurRadius: 3,
                                spreadRadius: 1,
                                offset: Offset(0, 0),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // Lock icon underneath, aligned with threshold marker
                SizedBox(
                  height: 18,
                  child: Stack(
                    children: [
                      Positioned(
                        left: (thresholdPos - 10).clamp(
                          0.0,
                          barWidth - 12,
                        ), // icon width ~12
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final totalGuardians = _peers?.length ?? 0;
    final thresh = threshold(totalGuardians);
    final onlineGuardians = _peers?.where((p) => p.online).toList() ?? [];
    final isFederationOnline =
        totalGuardians > 0 && onlineGuardians.length >= thresh;

    Widget federationInfo = Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: SizedBox(
            width: 155,
            height: 152,
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
        const SizedBox(height: 16),
        Text(
          widget.fed.federationName,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.bold,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );

    Widget buttons = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ElevatedButton(
          onPressed: () {
            _onJoinPressed(false);
          },
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
              isJoining
                  ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                      color: Colors.black,
                      strokeWidth: 2,
                    ),
                  )
                  : widget.ecash == null
                  ? const Text("Join Federation")
                  : const Text("Join and Redeem Ecash"),
        ),
        if (!isJoining) ...[
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () {
              _onJoinPressed(true);
            },
            icon: const Icon(Icons.history),
            label: const Text('Recover'),
            style: OutlinedButton.styleFrom(
              foregroundColor: theme.colorScheme.secondary,
              side: BorderSide(
                color: theme.colorScheme.secondary.withOpacity(0.5),
              ),
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              textStyle: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ],
    );

    return DefaultTabController(
      length: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.fed.network?.toLowerCase() != 'bitcoin') ...[
                Container(
                  margin: const EdgeInsets.only(bottom: 16),
                  padding: const EdgeInsets.all(12),
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
                          'Warning: This is a test network (${widget.fed.network}) and is not worth anything.',
                          style: const TextStyle(color: Colors.orange),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              if (widget.joinable) ...[
                Row(
                  children: [
                    // Left half: image + name, centered vertically
                    Expanded(
                      flex: 1,
                      child: Align(
                        alignment: Alignment.center,
                        child: federationInfo,
                      ),
                    ),

                    const SizedBox(width: 16),

                    // Right half: buttons
                    Expanded(flex: 1, child: buttons),
                  ],
                ),
              ] else ...[
                // Original layout if not joinable
                Center(child: federationInfo),
              ],

              if (widget.welcomeMessage != null) ...[
                const SizedBox(height: 12),
                Text(
                  widget.welcomeMessage!,
                  style: theme.textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
              ],

              const SizedBox(height: 16),

              _buildHealthStatusBar(
                theme: theme,
                onlineCount: onlineGuardians.length,
                totalCount: totalGuardians,
                threshold: thresh,
              ),

              const SizedBox(height: 24),

              TabBar(
                labelColor: theme.colorScheme.primary,
                unselectedLabelColor: Colors.grey,
                indicatorColor: theme.colorScheme.primary,
                tabs: const [Tab(text: 'Guardians'), Tab(text: 'UTXOs')],
              ),

              SizedBox(
                height: 300,
                child: TabBarView(
                  children: [
                    _buildGuardianList(
                      thresh,
                      totalGuardians,
                      isFederationOnline,
                    ),
                    FederationUtxoList(
                      invite: widget.inviteCode,
                      fed: widget.fed,
                      isFederationOnline: isFederationOnline,
                    ),
                  ],
                ),
              ),

              if (!widget.joinable) ...[
                const SizedBox(height: 24),

                GestureDetector(
                  onTap: () {
                    setState(() {
                      _showAdvanced = !_showAdvanced;
                    });
                  },
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _showAdvanced ? Icons.expand_less : Icons.expand_more,
                        color: theme.colorScheme.secondary,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        "Advanced",
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: theme.colorScheme.secondary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),

                if (_showAdvanced) ...[
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _onLeavePressed,
                    icon: const Icon(Icons.logout),
                    label: const Text("Leave Federation"),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red,
                      side: const BorderSide(color: Colors.red),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      textStyle: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGuardianList(int thresh, int total, bool isFederationOnline) {
    return _peers != null && _peers!.isNotEmpty
        ? ListView.builder(
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
                      ? Text('Version: ${widget.guardians![index].version}')
                      : const Text('Offline'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!widget.joinable && isFederationOnline) ...[
                    // Copy invite code button
                    IconButton(
                      tooltip: "Copy invite code",
                      icon: const Icon(Icons.copy, size: 20),
                      onPressed: () async {
                        try {
                          final inviteCode = await getInviteCode(
                            federationId: widget.fed.federationId,
                            peer: index,
                          );
                          if (!context.mounted) return;
                          await Clipboard.setData(
                            ClipboardData(text: inviteCode),
                          );
                          ToastService().show(
                            message: "Invite code for ${peer.name} copied",
                            duration: const Duration(seconds: 5),
                            onTap: () {},
                            icon: Icon(Icons.check),
                          );
                        } catch (e) {
                          AppLogger.instance.error(
                            "Error getting invite code: $e",
                          );
                          ToastService().show(
                            message: "Could not get invite code",
                            duration: const Duration(seconds: 5),
                            onTap: () {},
                            icon: Icon(Icons.error),
                          );
                        }
                      },
                    ),

                    // Show invite code popup button
                    IconButton(
                      tooltip: "View invite code",
                      icon: const Icon(Icons.qr_code, size: 20),
                      onPressed: () async {
                        try {
                          final inviteCode = await getInviteCode(
                            federationId: widget.fed.federationId,
                            peer: index,
                          );
                          if (!context.mounted) return;
                          showDialog(
                            context: context,
                            builder:
                                (context) => AlertDialog(
                                  title: const Center(
                                    child: Text(
                                      "Invite Code",
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
                                                            rootNavigator: true,
                                                          ).pop(),
                                                  child: Container(
                                                    width: double.infinity,
                                                    height: double.infinity,
                                                    color: Colors.black
                                                        .withOpacity(0.9),
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
                                      child: const Text("Close"),
                                    ),
                                  ],
                                ),
                          );
                        } catch (e) {
                          AppLogger.instance.error(
                            "Error getting invite code: $e",
                          );
                          ToastService().show(
                            message: "Could not get invite code",
                            duration: const Duration(seconds: 5),
                            onTap: () {},
                            icon: Icon(Icons.error),
                          );
                        }
                      },
                    ),
                  ],
                ],
              ),
            );
          },
        )
        : const Center(child: Text("Loading..."));
  }
}

class FederationUtxoList extends StatefulWidget {
  final String? invite;
  final FederationSelector fed;
  final bool isFederationOnline;

  const FederationUtxoList({
    super.key,
    required this.invite,
    required this.fed,
    required this.isFederationOnline,
  });

  @override
  State<FederationUtxoList> createState() => _FederationUtxoListState();
}

class _FederationUtxoListState extends State<FederationUtxoList> {
  List<Utxo>? utxos;

  @override
  void initState() {
    super.initState();
    _loadWalletSummary();
  }

  Future<void> _loadWalletSummary() async {
    if (widget.isFederationOnline) {
      try {
        final summary = await walletSummary(
          invite: widget.invite,
          federationId: widget.fed.federationId,
        );
        setState(() {
          utxos = summary;
        });
      } catch (e) {
        AppLogger.instance.error("Could not load wallet summary: $e");
        ToastService().show(
          message: "Could not load Federation's UTXOs",
          duration: const Duration(seconds: 5),
          onTap: () {},
          icon: Icon(Icons.error),
        );
      }
    }
  }

  // Abbreviate the txid with the middle replaced by "..."
  String abbreviateTxid(String txid, {int headLength = 8, int tailLength = 8}) {
    if (txid.length <= headLength + tailLength) return txid;
    final head = txid.substring(0, headLength);
    final tail = txid.substring(txid.length - tailLength);
    return '$head...$tail';
  }

  @override
  Widget build(BuildContext context) {
    final bitcoinDisplay = context.select<PreferencesProvider, BitcoinDisplay>(
      (prefs) => prefs.bitcoinDisplay,
    );

    if (!widget.isFederationOnline) {
      return const Center(
        child: Text("Federation is offline, cannot retrieve UTXOs."),
      );
    }

    if (utxos == null) {
      return const Center(child: CircularProgressIndicator());
    }

    if (utxos!.isEmpty) {
      return const Center(child: Text("No UTXOs found."));
    }

    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: utxos!.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final utxo = utxos![index];
        final explorerUrl = explorerUrlForNetwork(
          utxo.txid,
          widget.fed.network,
        );
        final abbreviatedTxid = abbreviateTxid(utxo.txid);
        final txidLabel = "$abbreviatedTxid:${utxo.index}";

        return Container(
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A),
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Row with TxID:index left, explorer link right
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      txidLabel,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 14,
                        color: Theme.of(context).colorScheme.primary,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),

                  IconButton(
                    tooltip: 'Copy txid',
                    icon: const Icon(Icons.copy),
                    color: Theme.of(context).colorScheme.secondary,
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: utxo.txid));
                      if (!context.mounted) return;
                      ToastService().show(
                        message: "Txid $abbreviatedTxid copied",
                        duration: const Duration(seconds: 2),
                        onTap: () {},
                        icon: Icon(Icons.check),
                      );
                    },
                  ),

                  if (explorerUrl != null)
                    IconButton(
                      tooltip: 'View on mempool.space',
                      icon: const Icon(Icons.open_in_new),
                      color: Theme.of(context).colorScheme.secondary,
                      onPressed: () async {
                        final url = Uri.parse(explorerUrl);
                        await showExplorerConfirmation(context, url);
                      },
                    ),
                ],
              ),

              const SizedBox(height: 8),

              // Amount below
              Text(
                formatBalance(utxo.amount, false, bitcoinDisplay),
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
