import 'package:ecashapp/db.dart';
import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/providers/preferences_provider.dart';
import 'package:ecashapp/theme.dart';
import 'package:ecashapp/toast.dart';
import 'package:ecashapp/utils.dart';
import 'package:ecashapp/widgets/gateway_details.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// A gateway on this guardian's whitelist, enriched with the routing info the
/// gateway itself advertises. [details] is null when the gateway did not
/// respond — it stays listed so the operator can still remove it.
class _WhitelistedGateway {
  final String url;
  final FedimintGateway? details;

  const _WhitelistedGateway({required this.url, this.details});
}

/// Management of a single guardian's lnv2 gateway whitelist.
///
/// The whitelist is per-guardian state: listing queries this guardian
/// directly, and add/remove mutate only this guardian's list.
class GuardianGatewaysScreen extends StatefulWidget {
  final FederationSelector fed;
  final PeerStatus peer;
  final String password;

  const GuardianGatewaysScreen({
    super.key,
    required this.fed,
    required this.peer,
    required this.password,
  });

  @override
  State<GuardianGatewaysScreen> createState() => _GuardianGatewaysScreenState();
}

class _GuardianGatewaysScreenState extends State<GuardianGatewaysScreen> {
  List<_WhitelistedGateway>? _gateways;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
    });
    try {
      // The whitelist decides which rows exist (it is what add/remove act on);
      // the federation-wide list only supplies alias/fee/node details, and is
      // allowed to fail without emptying the screen.
      final whitelist = await guardianListGateways(
        federationId: widget.fed.federationId,
        peer: widget.peer.peerId,
      );

      List<FedimintGateway> detailed = [];
      try {
        detailed = await listGateways(federationId: widget.fed.federationId);
      } catch (e) {
        AppLogger.instance.warn("Could not load gateway details: $e");
      }

      final byEndpoint = {
        for (final gateway in detailed.where((g) => g.isLnv2))
          gateway.endpoint: gateway,
      };

      if (!mounted) return;
      setState(() {
        _gateways =
            whitelist
                .map(
                  (url) =>
                      _WhitelistedGateway(url: url, details: byEndpoint[url]),
                )
                .toList();
      });
    } catch (e) {
      AppLogger.instance.error("Could not load guardian gateways: $e");
      if (!mounted) return;
      setState(() {
        _error = e;
      });
    }
  }

  void _showToast(String message, IconData icon) {
    ToastService().show(
      message: message,
      duration: const Duration(seconds: 5),
      onTap: () {},
      icon: Icon(icon),
    );
  }

  Future<void> _onAddPressed() async {
    final urlController = TextEditingController();

    await showDialog(
      context: context,
      builder: (dialogContext) {
        bool isAdding = false;

        return StatefulBuilder(
          builder: (sbContext, setState) {
            // Resolved up front: the dialog is popped before these are used,
            // so its context is no longer valid to read strings from.
            final addedMessage = sbContext.l10n.guardianGatewayAdded;
            final alreadyPresentMessage =
                sbContext.l10n.guardianGatewayAlreadyPresent;

            Future<void> submit() async {
              final url = urlController.text.trim();
              if (url.isEmpty || isAdding) return;
              setState(() {
                isAdding = true;
              });

              try {
                final added = await guardianAddGateway(
                  federationId: widget.fed.federationId,
                  peer: widget.peer.peerId,
                  password: widget.password,
                  gatewayUrl: url,
                );
                if (dialogContext.mounted) {
                  Navigator.of(dialogContext).pop();
                }
                _showToast(
                  added ? addedMessage : alreadyPresentMessage,
                  added ? Icons.check : Icons.info_outline,
                );
                _load();
              } catch (e) {
                AppLogger.instance.error("Could not add gateway: $e");
                if (!sbContext.mounted) return;
                setState(() {
                  isAdding = false;
                });
                _showToast(
                  sbContext.l10n.guardianCouldNotAddGateway,
                  Icons.error,
                );
              }
            }

            return AlertDialog(
              title: Text(sbContext.l10n.guardianAddGateway),
              content: TextField(
                controller: urlController,
                autofocus: true,
                enabled: !isAdding,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  labelText: sbContext.l10n.guardianGatewayUrlLabel,
                  hintText: sbContext.l10n.guardianGatewayUrlHint,
                  helperText: sbContext.l10n.guardianGatewayUrlHelper,
                  helperMaxLines: 2,
                ),
                onSubmitted: (_) => submit(),
              ),
              actions: [
                TextButton(
                  onPressed:
                      isAdding ? null : () => Navigator.of(dialogContext).pop(),
                  child: Text(sbContext.l10n.cancel),
                ),
                TextButton(
                  onPressed: isAdding ? null : submit,
                  child:
                      isAdding
                          ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                          : Text(sbContext.l10n.guardianAddGateway),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _onRemovePressed(String gatewayUrl) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: Text(dialogContext.l10n.guardianRemoveGatewayConfirm),
            content: Text(
              gatewayUrl,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(dialogContext.l10n.cancel),
              ),
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(
                  dialogContext.l10n.confirm,
                  style: const TextStyle(color: Colors.red),
                ),
              ),
            ],
          ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await guardianRemoveGateway(
        federationId: widget.fed.federationId,
        peer: widget.peer.peerId,
        password: widget.password,
        gatewayUrl: gatewayUrl,
      );
      if (!mounted) return;
      _showToast(context.l10n.guardianGatewayRemoved, Icons.check);
      _load();
    } catch (e) {
      AppLogger.instance.error("Could not remove gateway: $e");
      if (!mounted) return;
      _showToast(context.l10n.guardianCouldNotRemoveGateway, Icons.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Text(context.l10n.guardianGatewaysTitle),
      ),
      floatingActionButton:
          _gateways != null
              ? FloatingActionButton(
                tooltip: context.l10n.guardianAddGateway,
                onPressed: _onAddPressed,
                child: const Icon(Icons.add),
              )
              : null,
      body: SafeArea(child: _buildBody(theme)),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, size: 48, color: Colors.grey),
              const SizedBox(height: 16),
              Text(
                context.l10n.guardianCouldNotLoadGateways,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(color: Colors.grey),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: Text(context.l10n.retry),
              ),
            ],
          ),
        ),
      );
    }

    final gateways = _gateways;
    if (gateways == null) {
      return const Center(child: CircularProgressIndicator());
    }

    if (gateways.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.bolt_outlined, size: 48, color: Colors.grey),
            const SizedBox(height: 16),
            Text(
              context.l10n.guardianNoGateways,
              style: theme.textTheme.bodyMedium?.copyWith(color: Colors.grey),
            ),
          ],
        ),
      );
    }

    final bitcoinDisplay = context.select<PreferencesProvider, BitcoinDisplay>(
      (prefs) => prefs.bitcoinDisplay,
    );

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
        itemCount: gateways.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder:
            (context, index) =>
                _buildGatewayCard(theme, bitcoinDisplay, gateways[index]),
      ),
    );
  }

  Widget _buildGatewayCard(
    ThemeData theme,
    BitcoinDisplay bitcoinDisplay,
    _WhitelistedGateway gateway,
  ) {
    final details = gateway.details;

    return Material(
      color: const Color(0xFF1A1A1A),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap:
            details == null
                ? null
                : () => showAppModalBottomSheet(
                  context: context,
                  childBuilder:
                      () async => GatewayDetailsSheet(gateway: details),
                ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Row(
            children: [
              Icon(
                Icons.bolt_outlined,
                size: 20,
                color:
                    details == null ? Colors.grey : theme.colorScheme.primary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      details?.lightningAlias ?? gateway.url,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (details?.lightningAlias != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        gateway.url,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.grey,
                          fontFamily: 'monospace',
                          fontSize: 11,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    const SizedBox(height: 4),
                    Text(
                      details == null
                          ? context.l10n.guardianGatewayUnreachable
                          : '${formatBalance(details.baseRoutingFee, true, bitcoinDisplay)} + ${details.ppmRoutingFee} ppm',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: details == null ? Colors.orange : Colors.white60,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: context.l10n.guardianRemoveGatewayConfirm,
                icon: const Icon(Icons.delete_outline, size: 20),
                color: Colors.red,
                onPressed: () => _onRemovePressed(gateway.url),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
