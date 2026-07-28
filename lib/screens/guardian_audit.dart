import 'package:ecashapp/db.dart';
import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/providers/preferences_provider.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// Balance sheet of a single guardian: the federation's net assets and the
/// per-module breakdown, from the authenticated `audit` endpoint.
class GuardianAuditScreen extends StatefulWidget {
  final FederationSelector fed;
  final PeerStatus peer;
  final String password;

  const GuardianAuditScreen({
    super.key,
    required this.fed,
    required this.peer,
    required this.password,
  });

  @override
  State<GuardianAuditScreen> createState() => _GuardianAuditScreenState();
}

class _GuardianAuditScreenState extends State<GuardianAuditScreen> {
  GuardianAuditSummary? _audit;
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
      final audit = await guardianAudit(
        federationId: widget.fed.federationId,
        peer: widget.peer.peerId,
        password: widget.password,
      );
      if (!mounted) return;
      setState(() {
        _audit = audit;
      });
    } catch (e) {
      AppLogger.instance.error("Could not load guardian audit: $e");
      if (!mounted) return;
      setState(() {
        _error = e;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bitcoinDisplay = context.select<PreferencesProvider, BitcoinDisplay>(
      (prefs) => prefs.bitcoinDisplay,
    );

    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Text(context.l10n.guardianBalanceSheet),
      ),
      body: SafeArea(child: _buildBody(theme, bitcoinDisplay)),
    );
  }

  Widget _buildBody(ThemeData theme, BitcoinDisplay bitcoinDisplay) {
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
                context.l10n.guardianDashboardLoadFailed,
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

    final audit = _audit;
    if (audit == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          // Net assets headline
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1A),
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
            child: Column(
              children: [
                Text(
                  context.l10n.guardianNetAssets,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: Colors.grey,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  formatBalance(
                    BigInt.from(audit.netAssetsMsats),
                    false,
                    bitcoinDisplay,
                  ),
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // Per-module breakdown
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1A),
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final module in audit.moduleSummaries) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Flexible(
                          child: Text(
                            '${module.kind} · #${module.moduleInstanceId}',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: Colors.grey,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          formatBalance(
                            BigInt.from(module.netAssetsMsats),
                            false,
                            bitcoinDisplay,
                          ),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (module != audit.moduleSummaries.last)
                    Divider(
                      height: 1,
                      color: Colors.grey.withValues(alpha: 0.15),
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
