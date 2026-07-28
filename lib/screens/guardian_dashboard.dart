import 'package:ecashapp/db.dart';
import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/providers/preferences_provider.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// Admin dashboard for a single guardian, shown after a successful login.
///
/// The password is held in memory only and sent with every authenticated
/// request, which is how fedimint's admin API works (there is no session).
class GuardianDashboardScreen extends StatefulWidget {
  final FederationSelector fed;
  final PeerStatus peer;
  final String password;

  const GuardianDashboardScreen({
    super.key,
    required this.fed,
    required this.peer,
    required this.password,
  });

  @override
  State<GuardianDashboardScreen> createState() =>
      _GuardianDashboardScreenState();
}

class _GuardianDashboardScreenState extends State<GuardianDashboardScreen> {
  GuardianAuditSummary? _audit;
  GuardianBackupStatistics? _backups;
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
      final results = await Future.wait<Object>([
        guardianAudit(
          federationId: widget.fed.federationId,
          peer: widget.peer.peerId,
          password: widget.password,
        ),
        guardianBackupStatistics(
          federationId: widget.fed.federationId,
          peer: widget.peer.peerId,
          password: widget.password,
        ),
      ]);
      if (!mounted) return;
      setState(() {
        _audit = results[0] as GuardianAuditSummary;
        _backups = results[1] as GuardianBackupStatistics;
      });
    } catch (e) {
      AppLogger.instance.error("Could not load guardian dashboard: $e");
      if (!mounted) return;
      setState(() {
        _error = e;
      });
    }
  }

  String _formatBytes(BigInt bytes) {
    final kib = BigInt.from(1024);
    if (bytes < kib) return '$bytes B';
    if (bytes < kib * kib) {
      return '${(bytes.toDouble() / 1024).toStringAsFixed(1)} KiB';
    }
    return '${(bytes.toDouble() / (1024 * 1024)).toStringAsFixed(1)} MiB';
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
        title: Text(context.l10n.guardianDashboardTitle),
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

    if (_audit == null || _backups == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          _buildGuardianCard(theme),
          const SizedBox(height: 12),
          _buildBalanceSheetCard(theme, bitcoinDisplay),
          const SizedBox(height: 12),
          _buildBackupsCard(theme),
        ],
      ),
    );
  }

  Widget _card({required List<Widget> children}) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  Widget _cardTitle(ThemeData theme, IconData icon, String title) {
    return Row(
      children: [
        Icon(icon, size: 20, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Text(
          title,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  Widget _statRow(ThemeData theme, String label, String value) {
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
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGuardianCard(ThemeData theme) {
    return _card(
      children: [
        Row(
          children: [
            Icon(
              Icons.shield_outlined,
              size: 32,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.peer.name,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (widget.peer.version != null)
                    Text(
                      context.l10n.versionLabel(widget.peer.version!),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.grey,
                      ),
                    ),
                  Text(
                    widget.peer.url,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.grey,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildBalanceSheetCard(
    ThemeData theme,
    BitcoinDisplay bitcoinDisplay,
  ) {
    final audit = _audit!;
    return _card(
      children: [
        _cardTitle(
          theme,
          Icons.account_balance_outlined,
          context.l10n.guardianBalanceSheet,
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              context.l10n.guardianNetAssets,
              style: theme.textTheme.bodyMedium?.copyWith(color: Colors.grey),
            ),
            Text(
              formatBalance(
                BigInt.from(audit.netAssetsMsats),
                false,
                bitcoinDisplay,
              ),
              style: theme.textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.primary,
              ),
            ),
          ],
        ),
        const Divider(height: 24),
        ...audit.moduleSummaries.map(
          (module) => _statRow(
            theme,
            '${module.kind} · #${module.moduleInstanceId}',
            formatBalance(
              BigInt.from(module.netAssetsMsats),
              false,
              bitcoinDisplay,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBackupsCard(ThemeData theme) {
    final backups = _backups!;
    return _card(
      children: [
        _cardTitle(
          theme,
          Icons.cloud_outlined,
          context.l10n.guardianEcashBackups,
        ),
        const SizedBox(height: 8),
        _statRow(
          theme,
          context.l10n.guardianStoredBackups,
          backups.numBackups.toString(),
        ),
        _statRow(
          theme,
          context.l10n.guardianBackupsTotalSize,
          _formatBytes(backups.totalSizeBytes),
        ),
        const Divider(height: 24),
        _statRow(
          theme,
          context.l10n.guardianRefreshedLastDay,
          backups.refreshed1D.toString(),
        ),
        _statRow(
          theme,
          context.l10n.guardianRefreshedLastWeek,
          backups.refreshed1W.toString(),
        ),
        _statRow(
          theme,
          context.l10n.guardianRefreshedLastMonth,
          backups.refreshed1M.toString(),
        ),
        _statRow(
          theme,
          context.l10n.guardianRefreshedLast3Months,
          backups.refreshed3M.toString(),
        ),
      ],
    );
  }
}
