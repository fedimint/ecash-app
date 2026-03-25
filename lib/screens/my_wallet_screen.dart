import 'package:ecashapp/db.dart';
import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/providers/preferences_provider.dart';
import 'package:ecashapp/utils.dart';
import 'package:ecashapp/screens/federation_info_screen.dart';
import 'package:ecashapp/widgets/addresses.dart';
import 'package:ecashapp/widgets/ln_address_dialog.dart';
import 'package:ecashapp/widgets/note_summary.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

enum _WalletSection { summary, addresses, notes }

class MyWalletScreen extends StatefulWidget {
  final FederationSelector fed;
  final VoidCallback? onAddressesUpdated;
  final VoidCallback? onLeaveFederation;

  const MyWalletScreen({
    super.key,
    required this.fed,
    this.onAddressesUpdated,
    this.onLeaveFederation,
  });

  @override
  State<MyWalletScreen> createState() => _MyWalletScreenState();
}

class _MyWalletScreenState extends State<MyWalletScreen> {
  _WalletSection _selectedSection = _WalletSection.summary;
  BigInt? _balanceMsats;
  bool _isLoadingBalance = true;
  bool _showMsats = false;
  Map<FiatCurrency, double> _btcPrices = {};
  bool _isLoadingPrices = true;

  // Summary data
  List<(BigInt, BigInt)>? _noteSummary;
  List<(String, BigInt, BigInt?)>? _addresses;
  LightningAddressConfig? _lnAddressConfig;
  bool _isSummaryLoading = true;

  @override
  void initState() {
    super.initState();
    _loadBalance();
    _loadBtcPrices();
    _loadSummaryData();
  }

  Future<void> _loadBalance() async {
    final bal = await balance(federationId: widget.fed.federationId);
    if (!mounted) return;
    setState(() {
      _balanceMsats = bal;
      _isLoadingBalance = false;
    });
  }

  Future<void> _loadBtcPrices() async {
    final prices = await fetchAllBtcPrices();
    if (!mounted) return;
    setState(() {
      _btcPrices = prices;
      _isLoadingPrices = false;
    });
  }

  Future<void> _loadSummaryData() async {
    try {
      final results = await Future.wait([
        getNoteSummary(federationId: widget.fed.federationId),
        getAddresses(federationId: widget.fed.federationId),
        getLnAddressConfig(federationId: widget.fed.federationId),
      ]);
      if (!mounted) return;
      setState(() {
        _noteSummary = results[0] as List<(BigInt, BigInt)>;
        _addresses = results[1] as List<(String, BigInt, BigInt?)>;
        _lnAddressConfig = results[2] as LightningAddressConfig?;
        _isSummaryLoading = false;
      });
    } catch (e) {
      AppLogger.instance.error("Error loading wallet summary: $e");
      if (!mounted) return;
      setState(() {
        _isSummaryLoading = false;
      });
    }
  }

  Widget _buildSectionChips(ThemeData theme) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _buildChip(
          theme: theme,
          label: context.l10n.summary,
          icon: Icons.dashboard_outlined,
          section: _WalletSection.summary,
        ),
        const SizedBox(width: 8),
        _buildChip(
          theme: theme,
          label: context.l10n.addresses,
          icon: Icons.account_balance_wallet_outlined,
          section: _WalletSection.addresses,
        ),
        const SizedBox(width: 8),
        _buildChip(
          theme: theme,
          label: context.l10n.notes,
          icon: Icons.receipt_long_outlined,
          section: _WalletSection.notes,
        ),
      ],
    );
  }

  Widget _buildChip({
    required ThemeData theme,
    required String label,
    required IconData icon,
    required _WalletSection section,
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

  Widget _buildSummaryContent(ThemeData theme) {
    if (_isSummaryLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final totalNotes =
        _noteSummary?.fold<int>(0, (sum, entry) => sum + entry.$2.toInt()) ?? 0;
    final denomCount = _noteSummary?.length ?? 0;
    final addressCount = _addresses?.length ?? 0;
    final fundedCount = _addresses?.where((a) => a.$3 != null).length ?? 0;

    return ListView(
      padding: const EdgeInsets.only(top: 8),
      children: [
        // Ecash notes card
        _buildSummaryCard(
          theme: theme,
          icon: Icons.receipt_long,
          title: context.l10n.ecashNotesCount(totalNotes),
          subtitle: context.l10n.acrossDenominations(denomCount),
          onTap:
              () => setState(() {
                _selectedSection = _WalletSection.notes;
              }),
        ),
        const SizedBox(height: 8),
        // Addresses card
        _buildSummaryCard(
          theme: theme,
          icon: Icons.account_balance_wallet,
          title: context.l10n.depositAddressesCount(addressCount),
          subtitle: context.l10n.addressesWithFunds(fundedCount),
          onTap:
              () => setState(() {
                _selectedSection = _WalletSection.addresses;
              }),
        ),
        // Lightning address card
        if (_lnAddressConfig != null) ...[
          const SizedBox(height: 8),
          _buildSummaryCard(
            theme: theme,
            icon: Icons.flash_on,
            iconColor: Colors.amber,
            title: context.l10n.lightningAddress,
            subtitle:
                '${_lnAddressConfig!.username}@${_lnAddressConfig!.domain}',
            onTap:
                () => showLightningAddressDialog(
                  context,
                  _lnAddressConfig!.username,
                  _lnAddressConfig!.domain,
                  _lnAddressConfig!.lnurl,
                ),
          ),
        ],
        const SizedBox(height: 8),
        // Federation card
        _buildSummaryCard(
          theme: theme,
          icon: Icons.groups_outlined,
          title: context.l10n.federation,
          subtitle: widget.fed.federationName,
          onTap: () async {
            final meta = await getFederationMeta(
              federationId: widget.fed.federationId,
            );
            if (!mounted) return;
            Navigator.of(context).push(
              MaterialPageRoute(
                builder:
                    (_) => FederationInfoScreen(
                      fed: widget.fed,
                      welcomeMessage: meta.welcome,
                      imageUrl: meta.picture,
                      guardians: meta.guardians,
                      onLeaveFederation: widget.onLeaveFederation ?? () {},
                    ),
              ),
            );
          },
        ),
        // Network card
        if (widget.fed.network != null) ...[
          const SizedBox(height: 8),
          _buildSummaryCard(
            theme: theme,
            icon: Icons.lan_outlined,
            title: context.l10n.network,
            subtitle: widget.fed.network!,
          ),
        ],
      ],
    );
  }

  Widget _buildSummaryCard({
    required ThemeData theme,
    required IconData icon,
    required String title,
    required String subtitle,
    Color? iconColor,
    VoidCallback? onTap,
    Widget? trailing,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: theme.colorScheme.primary.withValues(alpha: 0.15),
          ),
        ),
        child: Row(
          children: [
            Icon(icon, color: iconColor ?? theme.colorScheme.primary, size: 24),
            const SizedBox(width: 14),
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
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: Colors.grey,
                    ),
                  ),
                ],
              ),
            ),
            if (trailing != null) trailing,
            if (onTap != null && trailing == null)
              Icon(
                Icons.chevron_right,
                color: Colors.grey.withValues(alpha: 0.5),
                size: 20,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSelectedContent() {
    switch (_selectedSection) {
      case _WalletSection.summary:
        return _buildSummaryContent(Theme.of(context));
      case _WalletSection.addresses:
        return OnchainAddressesList(
          fed: widget.fed,
          updateAddresses: widget.onAddressesUpdated ?? () {},
        );
      case _WalletSection.notes:
        return NoteSummary(fed: widget.fed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bitcoinDisplay = context.select<PreferencesProvider, BitcoinDisplay>(
      (prefs) => prefs.bitcoinDisplay,
    );
    final fiatCurrency = context.select<PreferencesProvider, FiatCurrency>(
      (prefs) => prefs.fiatCurrency,
    );

    return Scaffold(
      appBar: AppBar(centerTitle: true, title: Text(context.l10n.myWallet)),
      body: SafeArea(
        child: Column(
          children: [
            // Balance header
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child:
                  _isLoadingBalance
                      ? const SizedBox(
                        height: 48,
                        child: Center(child: CircularProgressIndicator()),
                      )
                      : GestureDetector(
                        onTap: () => setState(() => _showMsats = !_showMsats),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              formatBalance(
                                _balanceMsats,
                                _showMsats,
                                bitcoinDisplay,
                              ),
                              style: theme.textTheme.displayLarge?.copyWith(
                                color: theme.colorScheme.primary,
                                fontWeight: FontWeight.bold,
                                fontSize: 36,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            if (!_isLoadingPrices && _btcPrices.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(
                                calculateFiatValue(
                                  _btcPrices[fiatCurrency],
                                  (_balanceMsats != null
                                          ? _balanceMsats! ~/ BigInt.from(1000)
                                          : BigInt.zero)
                                      .toInt(),
                                  fiatCurrency,
                                ),
                                style: const TextStyle(
                                  fontSize: 20,
                                  color: Colors.grey,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ],
                        ),
                      ),
            ),
            const SizedBox(height: 12),
            _buildSectionChips(theme),
            const SizedBox(height: 8),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: _buildSelectedContent(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
