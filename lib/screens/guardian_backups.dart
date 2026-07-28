import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';

/// One recency cohort of backups: how many were last refreshed within a
/// window, and how that window should read.
class _Cohort {
  final String label;
  final int count;
  final Color color;

  const _Cohort({
    required this.label,
    required this.count,
    required this.color,
  });
}

/// Ordinal blue ramp, fresh to stale, validated for monotone lightness and
/// contrast against this screen's dark surface. Dormant backups fall out of
/// the ramp into neutral grey — they are an absence of activity, not a step.
const _freshest = Color(0xFF9EC5F4);
const _fresh = Color(0xFF5598E7);
const _older = Color(0xFF2A78D6);
const _oldest = Color(0xFF1C5CAB);
const _dormant = Color(0xFF4A4A48);

/// Client backup storage on a single guardian, from the authenticated
/// `backup_statistics` endpoint.
///
/// The endpoint's refresh counts are cumulative — a backup refreshed today is
/// counted in the day, week, month and quarter figures alike — so this screen
/// converts them into exclusive cohorts before showing them. Presented raw
/// they read as independent buckets that ought to sum to the total, and don't.
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
  bool _explainerOpen = false;

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

  /// Turns the endpoint's nested windows into non-overlapping cohorts that
  /// sum to the total. Clamped at zero so a count sampled mid-change can never
  /// render a negative segment.
  List<_Cohort> _cohorts(GuardianBackupStatistics b) {
    int diff(BigInt wider, BigInt narrower) {
      final value = (wider - narrower).toInt();
      return value < 0 ? 0 : value;
    }

    return [
      _Cohort(
        label: context.l10n.guardianBackupsToday,
        count: b.refreshed1D.toInt(),
        color: _freshest,
      ),
      _Cohort(
        label: context.l10n.guardianBackupsThisWeek,
        count: diff(b.refreshed1W, b.refreshed1D),
        color: _fresh,
      ),
      _Cohort(
        label: context.l10n.guardianBackupsThisMonth,
        count: diff(b.refreshed1M, b.refreshed1W),
        color: _older,
      ),
      _Cohort(
        label: context.l10n.guardianBackupsThisQuarter,
        count: diff(b.refreshed3M, b.refreshed1M),
        color: _oldest,
      ),
      _Cohort(
        label: context.l10n.guardianBackupsDormant,
        count: diff(b.numBackups, b.refreshed3M),
        color: _dormant,
      ),
    ];
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

    final total = backups.numBackups.toInt();

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          _buildHeroCard(theme, backups, total),
          if (total > 0) ...[
            const SizedBox(height: 12),
            _buildActivityCard(theme, backups, total),
          ],
          const SizedBox(height: 16),
          _buildExplainer(theme),
        ],
      ),
    );
  }

  // --- Hero ---

  Widget _buildHeroCard(
    ThemeData theme,
    GuardianBackupStatistics backups,
    int total,
  ) {
    final activeMonth = backups.refreshed1M.toInt();
    final activeShare = total == 0 ? 0 : (activeMonth * 100 / total).round();

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _fresh.withValues(alpha: 0.14),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.shield_moon_outlined,
              size: 32,
              color: _freshest,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '$total',
            style: theme.textTheme.headlineLarge?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            context.l10n.guardianBackupsWalletsProtected,
            style: theme.textTheme.bodyMedium?.copyWith(color: Colors.grey),
            textAlign: TextAlign.center,
          ),
          if (total > 0) ...[
            const SizedBox(height: 14),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                _pill(
                  theme,
                  Icons.bolt_outlined,
                  context.l10n.guardianBackupsActiveShare('$activeShare'),
                ),
                _pill(
                  theme,
                  Icons.sd_storage_outlined,
                  _formatBytes(backups.totalSizeBytes),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _pill(ThemeData theme, IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.grey.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Colors.grey),
          const SizedBox(width: 6),
          Text(
            text,
            style: theme.textTheme.labelMedium?.copyWith(color: Colors.grey),
          ),
        ],
      ),
    );
  }

  // --- Activity composition ---

  Widget _buildActivityCard(
    ThemeData theme,
    GuardianBackupStatistics backups,
    int total,
  ) {
    final cohorts = _cohorts(backups);
    final visible = cohorts.where((c) => c.count > 0).toList();

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.l10n.guardianBackupsLastRefreshed,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 14),
          _stackedBar(visible, total),
          const SizedBox(height: 16),
          // Every segment is also named here, so the composition never depends
          // on colour alone.
          for (final cohort in visible) _legendRow(theme, cohort, total),
        ],
      ),
    );
  }

  Widget _stackedBar(List<_Cohort> cohorts, int total) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // A 2px surface gap separates adjacent fills so segment boundaries
        // stay legible without borders.
        const gap = 2.0;
        final gaps = cohorts.length > 1 ? (cohorts.length - 1) * gap : 0.0;
        final usable = (constraints.maxWidth - gaps).clamp(
          0.0,
          double.infinity,
        );

        return ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            height: 14,
            child: Row(
              children: [
                for (var i = 0; i < cohorts.length; i++) ...[
                  if (i > 0) const SizedBox(width: gap),
                  Container(
                    width: usable * (cohorts[i].count / total),
                    decoration: BoxDecoration(
                      color: cohorts[i].color,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _legendRow(ThemeData theme, _Cohort cohort, int total) {
    final percent = total == 0 ? 0 : (cohort.count * 100 / total).round();

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: cohort.color,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              cohort.label,
              style: theme.textTheme.bodyMedium?.copyWith(color: Colors.grey),
            ),
          ),
          Text(
            '${cohort.count}',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 42,
            child: Text(
              '$percent%',
              textAlign: TextAlign.right,
              style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
            ),
          ),
        ],
      ),
    );
  }

  // --- Explainer ---

  Widget _buildExplainer(ThemeData theme) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() => _explainerOpen = !_explainerOpen),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, size: 18, color: Colors.grey),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      context.l10n.guardianBackupsExplainerTitle,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Icon(
                    _explainerOpen ? Icons.expand_less : Icons.expand_more,
                    color: Colors.grey,
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            firstChild: const SizedBox(width: double.infinity),
            secondChild: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Text(
                context.l10n.guardianBackupsExplainerBody,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Colors.grey,
                  height: 1.5,
                ),
              ),
            ),
            crossFadeState:
                _explainerOpen
                    ? CrossFadeState.showSecond
                    : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 200),
          ),
        ],
      ),
    );
  }
}
