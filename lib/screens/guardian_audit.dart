import 'package:ecashapp/db.dart';
import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/providers/preferences_provider.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// Categorical colours for the holdings/owed comparison, stepped for this
/// screen's dark surface and validated for colour-vision separation. They are
/// deliberately not the status green/orange used for the verdict, which are
/// reserved for state.
const _holdingsColor = Color(0xFF3987E5);
const _owedColor = Color(0xFFD95926);

/// A module's contribution to the balance sheet, translated out of module
/// kinds into something an operator can read.
class _ModuleLine {
  final String title;
  final String subtitle;
  final IconData icon;
  final BigInt amountMsats;
  final bool isLiability;

  const _ModuleLine({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.amountMsats,
    required this.isLiability,
  });
}

/// The federation's balance sheet from the authenticated `audit` endpoint.
///
/// Modules report signed values: the wallet contributes the bitcoin it holds
/// (positive) and the mint contributes the ecash it has issued (negative,
/// because that value is owed to users). Net assets is therefore holdings
/// minus obligations — a solvency figure, which is what this screen leads with.
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

  /// Maps a module kind onto plain language. Unknown modules keep their kind
  /// so a new module type is never hidden from the balance sheet.
  _ModuleLine _describe(GuardianModuleSummary module) {
    final msats = BigInt.from(module.netAssetsMsats);
    final isLiability = module.netAssetsMsats < 0;
    final kind = module.kind;

    if (kind.startsWith('wallet')) {
      return _ModuleLine(
        title: context.l10n.guardianAuditWalletTitle,
        subtitle: context.l10n.guardianAuditWalletSubtitle,
        icon: Icons.currency_bitcoin,
        amountMsats: msats.abs(),
        isLiability: isLiability,
      );
    }
    if (kind.startsWith('mint')) {
      return _ModuleLine(
        title: context.l10n.guardianAuditMintTitle,
        subtitle: context.l10n.guardianAuditMintSubtitle,
        icon: Icons.toll_outlined,
        amountMsats: msats.abs(),
        isLiability: isLiability,
      );
    }
    if (kind.startsWith('ln')) {
      return _ModuleLine(
        title: context.l10n.guardianAuditLightningTitle,
        subtitle: context.l10n.guardianAuditLightningSubtitle,
        icon: Icons.bolt_outlined,
        amountMsats: msats.abs(),
        isLiability: isLiability,
      );
    }
    return _ModuleLine(
      title: kind,
      subtitle: context.l10n.guardianAuditOtherSubtitle,
      icon: Icons.extension_outlined,
      amountMsats: msats.abs(),
      isLiability: isLiability,
    );
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

    // Split the signed module values into what the federation holds and what
    // it owes, which is the comparison the verdict rests on.
    var holdings = BigInt.zero;
    var owed = BigInt.zero;
    for (final module in audit.moduleSummaries) {
      final msats = BigInt.from(module.netAssetsMsats);
      if (module.netAssetsMsats < 0) {
        owed += msats.abs();
      } else {
        holdings += msats;
      }
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          _buildVerdictCard(theme, bitcoinDisplay, audit),
          const SizedBox(height: 12),
          _buildComparisonCard(theme, bitcoinDisplay, holdings, owed),
          const SizedBox(height: 24),
          _sectionHeader(theme, context.l10n.guardianAuditWhereValueIs),
          const SizedBox(height: 8),
          _buildModulesCard(theme, bitcoinDisplay, audit),
          const SizedBox(height: 16),
          _buildExplainer(theme),
        ],
      ),
    );
  }

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

  // --- Verdict ---

  Widget _buildVerdictCard(
    ThemeData theme,
    BitcoinDisplay bitcoinDisplay,
    GuardianAuditSummary audit,
  ) {
    final net = audit.netAssetsMsats;
    final solvent = net >= 0;
    // Status colours, paired with an icon and a label so the state is never
    // carried by colour alone.
    final statusColor =
        solvent ? const Color(0xFF2E9E5B) : const Color(0xFFE34948);
    final icon = solvent ? Icons.verified_outlined : Icons.error_outline;
    final headline =
        solvent
            ? context.l10n.guardianAuditFullyBacked
            : context.l10n.guardianAuditUnderBacked;
    final explanation =
        net > 0
            ? context.l10n.guardianAuditReserveExplain
            : net == 0
            ? context.l10n.guardianAuditExactExplain
            : context.l10n.guardianAuditShortfallExplain;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: statusColor.withValues(alpha: 0.35)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 32, color: statusColor),
          ),
          const SizedBox(height: 12),
          Text(
            headline.toUpperCase(),
            style: theme.textTheme.labelLarge?.copyWith(
              color: statusColor,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            formatBalance(BigInt.from(net).abs(), false, bitcoinDisplay),
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Text(
            explanation,
            style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  // --- Holdings vs owed ---

  Widget _buildComparisonCard(
    ThemeData theme,
    BitcoinDisplay bitcoinDisplay,
    BigInt holdings,
    BigInt owed,
  ) {
    final max = holdings > owed ? holdings : owed;

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _comparisonBar(
            theme: theme,
            label: context.l10n.guardianAuditHoldings,
            amount: holdings,
            max: max,
            color: _holdingsColor,
            bitcoinDisplay: bitcoinDisplay,
          ),
          const SizedBox(height: 14),
          _comparisonBar(
            theme: theme,
            label: context.l10n.guardianAuditOwed,
            amount: owed,
            max: max,
            color: _owedColor,
            bitcoinDisplay: bitcoinDisplay,
          ),
        ],
      ),
    );
  }

  Widget _comparisonBar({
    required ThemeData theme,
    required String label,
    required BigInt amount,
    required BigInt max,
    required Color color,
    required BitcoinDisplay bitcoinDisplay,
  }) {
    final fraction =
        max == BigInt.zero ? 0.0 : (amount / max).clamp(0.0, 1.0).toDouble();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // Identity comes from the direct label plus the coloured bar, so
            // the comparison survives without colour.
            Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(color: Colors.grey),
            ),
            Text(
              formatBalance(amount, false, bitcoinDisplay),
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        LayoutBuilder(
          builder: (context, constraints) {
            return Stack(
              children: [
                Container(
                  height: 10,
                  decoration: BoxDecoration(
                    color: Colors.grey.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: fraction),
                  duration: const Duration(milliseconds: 650),
                  curve: Curves.easeOutCubic,
                  builder: (context, value, _) {
                    return Container(
                      height: 10,
                      width: constraints.maxWidth * value,
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    );
                  },
                ),
              ],
            );
          },
        ),
      ],
    );
  }

  // --- Module breakdown ---

  Widget _buildModulesCard(
    ThemeData theme,
    BitcoinDisplay bitcoinDisplay,
    GuardianAuditSummary audit,
  ) {
    final lines = audit.moduleSummaries.map(_describe).toList();

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < lines.length; i++) ...[
            _buildModuleRow(theme, bitcoinDisplay, lines[i]),
            if (i != lines.length - 1)
              Divider(height: 1, color: Colors.grey.withValues(alpha: 0.15)),
          ],
        ],
      ),
    );
  }

  Widget _buildModuleRow(
    ThemeData theme,
    BitcoinDisplay bitcoinDisplay,
    _ModuleLine line,
  ) {
    final color = line.isLiability ? _owedColor : _holdingsColor;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(line.icon, size: 20, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  line.title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  line.subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.grey,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                formatBalance(line.amountMsats, false, bitcoinDisplay),
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                line.isLiability
                    ? context.l10n.guardianAuditOwedTag
                    : context.l10n.guardianAuditHeldTag,
                style: theme.textTheme.labelSmall?.copyWith(color: Colors.grey),
              ),
            ],
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
                      context.l10n.guardianAuditExplainerTitle,
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
                context.l10n.guardianAuditExplainerBody,
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
