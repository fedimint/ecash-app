import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';

/// Client backup storage statistics for a single guardian, from the
/// authenticated `backup_statistics` endpoint.
class GuardianBackupsScreen extends StatefulWidget {
  final FederationSelector fed;
  final PeerStatus peer;
  final String password;

  const GuardianBackupsScreen({
    super.key,
    required this.fed,
    required this.peer,
    required this.password,
  });

  @override
  State<GuardianBackupsScreen> createState() => _GuardianBackupsScreenState();
}

class _GuardianBackupsScreenState extends State<GuardianBackupsScreen> {
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
      final backups = await guardianBackupStatistics(
        federationId: widget.fed.federationId,
        peer: widget.peer.peerId,
        password: widget.password,
      );
      if (!mounted) return;
      setState(() {
        _backups = backups;
      });
    } catch (e) {
      AppLogger.instance.error("Could not load guardian backups: $e");
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

    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Text(context.l10n.guardianEcashBackups),
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

    final backups = _backups;
    if (backups == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          // Headline: number of stored backups
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1A),
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
            child: Column(
              children: [
                Text(
                  context.l10n.guardianStoredBackups,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: Colors.grey,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  backups.numBackups.toString(),
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _formatBytes(backups.totalSizeBytes),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.grey,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // Refresh recency breakdown
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1A),
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
            ),
          ),
        ],
      ),
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
}
