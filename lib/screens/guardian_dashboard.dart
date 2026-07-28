import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/screens/guardian_audit.dart';
import 'package:ecashapp/screens/guardian_backups.dart';
import 'package:ecashapp/screens/guardian_gateways.dart';
import 'package:ecashapp/screens/guardian_meta.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';

/// Admin dashboard hub for a single guardian, shown after a successful login.
///
/// Shows the guardian's health and bitcoin node status up top, followed by a
/// list of detail screens to drill into (audit, backups, ...).
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
  GuardianStatusSummary? _status;
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
      final status = await guardianStatus(
        federationId: widget.fed.federationId,
        peer: widget.peer.peerId,
        password: widget.password,
      );
      if (!mounted) return;
      setState(() {
        _status = status;
      });
    } catch (e) {
      AppLogger.instance.error("Could not load guardian status: $e");
      if (!mounted) return;
      setState(() {
        _error = e;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Column(
          children: [
            Text(widget.peer.name, overflow: TextOverflow.ellipsis),
            if (widget.peer.version != null)
              Text(
                context.l10n.versionLabel(widget.peer.version!),
                style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
              ),
          ],
        ),
      ),
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

    final status = _status;
    if (status == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          _buildHealthCard(theme, status.health),
          if (status.bitcoin != null) ...[
            const SizedBox(height: 12),
            _buildBitcoinCard(theme, status.bitcoin!),
          ],
          const SizedBox(height: 24),
          _sectionHeader(theme, context.l10n.guardianManageSection),
          const SizedBox(height: 8),
          _manageTile(
            theme: theme,
            icon: Icons.account_balance_outlined,
            title: context.l10n.guardianBalanceSheet,
            subtitle: context.l10n.guardianBalanceSheetSubtitle,
            onTap:
                () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder:
                        (_) => GuardianAuditScreen(
                          fed: widget.fed,
                          peer: widget.peer,
                          password: widget.password,
                        ),
                  ),
                ),
          ),
          const SizedBox(height: 8),
          _manageTile(
            theme: theme,
            icon: Icons.cloud_outlined,
            title: context.l10n.guardianEcashBackups,
            subtitle: context.l10n.guardianEcashBackupsSubtitle,
            onTap:
                () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder:
                        (_) => GuardianBackupsScreen(
                          fed: widget.fed,
                          peer: widget.peer,
                          password: widget.password,
                        ),
                  ),
                ),
          ),
          if (status.hasMeta) ...[
            const SizedBox(height: 8),
            _manageTile(
              theme: theme,
              icon: Icons.tune_outlined,
              title: context.l10n.guardianMetaTitle,
              subtitle: context.l10n.guardianMetaSubtitle,
              onTap:
                  () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder:
                          (_) => GuardianMetaScreen(
                            fed: widget.fed,
                            peer: widget.peer,
                            password: widget.password,
                          ),
                    ),
                  ),
            ),
          ],
          if (status.hasLnv2) ...[
            const SizedBox(height: 8),
            _manageTile(
              theme: theme,
              icon: Icons.bolt_outlined,
              title: context.l10n.guardianGatewaysTitle,
              subtitle: context.l10n.guardianGatewaysSubtitle,
              onTap:
                  () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder:
                          (_) => GuardianGatewaysScreen(
                            fed: widget.fed,
                            peer: widget.peer,
                            password: widget.password,
                          ),
                    ),
                  ),
            ),
          ],
        ],
      ),
    );
  }

  // --- Summary cards ---

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

  Widget _warningRow(ThemeData theme, String message) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.orange.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            const Icon(Icons.warning_amber, size: 18, color: Colors.orange),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Colors.orange,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHealthCard(ThemeData theme, GuardianHealth health) {
    final statusColor = health.consensusRunning ? Colors.green : Colors.orange;
    final statusText =
        health.consensusRunning
            ? context.l10n.guardianStatusConsensusRunning
            : health.serverStatus;

    return _card(
      children: [
        _cardTitle(
          theme,
          Icons.monitor_heart_outlined,
          context.l10n.guardianHealthTitle,
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Icon(Icons.circle, size: 12, color: statusColor),
            const SizedBox(width: 8),
            Text(
              statusText,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: statusColor,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _statRow(
          theme,
          context.l10n.guardianConnectedGuardians,
          '${health.peersOnline} / ${health.peersTotal}',
        ),
        if (health.sessionCount != null)
          _statRow(
            theme,
            context.l10n.guardianSessionsLabel,
            health.sessionCount.toString(),
          ),
        if (health.consensusOrdLatencyMs != null)
          _statRow(
            theme,
            context.l10n.guardianLatencyLabel,
            '${health.consensusOrdLatencyMs} ms',
          ),
        if (health.scheduledShutdownSession != null)
          _warningRow(
            theme,
            context.l10n.guardianShutdownWarning(
              health.scheduledShutdownSession.toString(),
            ),
          ),
      ],
    );
  }

  Widget _buildBitcoinCard(ThemeData theme, GuardianBitcoinStatus bitcoin) {
    final local = bitcoin.localBlockCount;
    final behind =
        local != null && local < bitcoin.consensusBlockCount
            ? bitcoin.consensusBlockCount - local
            : BigInt.zero;

    return _card(
      children: [
        _cardTitle(
          theme,
          Icons.currency_bitcoin,
          context.l10n.guardianBitcoinTitle,
        ),
        if (bitcoin.kind != null || bitcoin.url != null) ...[
          const SizedBox(height: 4),
          Text(
            [bitcoin.kind, bitcoin.url].whereType<String>().join(' · '),
            style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
            overflow: TextOverflow.ellipsis,
          ),
        ],
        const SizedBox(height: 8),
        _statRow(
          theme,
          context.l10n.guardianChainHeightConsensus,
          bitcoin.consensusBlockCount.toString(),
        ),
        if (bitcoin.consensusFeerateSatsPerKvb != null)
          _statRow(
            theme,
            context.l10n.guardianConsensusFeerateLabel,
            '${(bitcoin.consensusFeerateSatsPerKvb!.toDouble() / 1000).toStringAsFixed(1)} sat/vB',
          ),
        if (local != null) ...[
          _statRow(
            theme,
            context.l10n.guardianChainHeightLocal,
            local.toString(),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(
                behind == BigInt.zero
                    ? Icons.check_circle
                    : Icons.warning_amber,
                size: 16,
                color: behind == BigInt.zero ? Colors.green : Colors.orange,
              ),
              const SizedBox(width: 6),
              Text(
                behind == BigInt.zero
                    ? context.l10n.guardianNodeSynced
                    : context.l10n.guardianNodeBehind(behind.toString()),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: behind == BigInt.zero ? Colors.green : Colors.orange,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  // --- Manage list ---

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

  Widget _manageTile({
    required ThemeData theme,
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Material(
      color: const Color(0xFF1A1A1A),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 22, color: theme.colorScheme.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.grey,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right, color: Colors.grey),
            ],
          ),
        ),
      ),
    );
  }
}
