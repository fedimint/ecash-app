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
  BigInt? _balanceMsats;
  bool _isLoadingBalance = true;
  Map<FiatCurrency, double> _btcPrices = {};
  bool _isLoadingPrices = true;

  // Summary data
  List<(BigInt, BigInt)>? _noteSummary;
  List<(String, BigInt, BigInt?)>? _addresses;
  LightningAddressConfig? _lnAddressConfig;
  FederationMeta? _federationMeta;
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
        getFederationMeta(federationId: widget.fed.federationId),
      ]);
      if (!mounted) return;
      setState(() {
        _noteSummary = results[0] as List<(BigInt, BigInt)>;
        _addresses = results[1] as List<(String, BigInt, BigInt?)>;
        _lnAddressConfig = results[2] as LightningAddressConfig?;
        _federationMeta = results[3] as FederationMeta;
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

  Widget _buildSectionHeader(
    ThemeData theme,
    String title,
    int count, {
    VoidCallback? onViewAll,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 8),
      child: Row(
        children: [
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              count.toString(),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const Spacer(),
          if (onViewAll != null)
            TextButton(
              onPressed: onViewAll,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    context.l10n.viewAll,
                    style: TextStyle(
                      color: theme.colorScheme.primary,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(width: 2),
                  Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFederationCard(ThemeData theme) {
    final guardianCount = _federationMeta?.guardians.length ?? 0;

    return GestureDetector(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder:
                (_) => FederationInfoScreen(
                  fed: widget.fed,
                  welcomeMessage: _federationMeta?.welcome,
                  imageUrl: _federationMeta?.picture,
                  guardians: _federationMeta?.guardians ?? [],
                  onLeaveFederation: widget.onLeaveFederation ?? () {},
                ),
          ),
        );
      },
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
            Icon(
              Icons.groups_outlined,
              color: theme.colorScheme.primary,
              size: 24,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.fed.federationName,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text(
                        context.l10n.guardiansCount(guardianCount),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: Colors.grey,
                        ),
                      ),
                      if (widget.fed.network != null) ...[
                        Text(
                          ' · ',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: Colors.grey,
                          ),
                        ),
                        Text(
                          widget.fed.network!,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: Colors.grey,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
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

  Widget _buildLightningAddressRow(ThemeData theme) {
    if (_lnAddressConfig == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: GestureDetector(
        onTap:
            () => showLightningAddressDialog(
              context,
              _lnAddressConfig!.username,
              _lnAddressConfig!.domain,
              _lnAddressConfig!.lnurl,
            ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.flash_on, color: Colors.amber, size: 14),
              const SizedBox(width: 4),
              Text(
                '${_lnAddressConfig!.username}@${_lnAddressConfig!.domain}',
                style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNoteRow(
    ThemeData theme,
    BigInt denom,
    BigInt count,
    BitcoinDisplay bitcoinDisplay,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.15),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.receipt_long, color: theme.colorScheme.primary, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              formatBalance(denom, true, bitcoinDisplay),
              style: theme.textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              'x${count.toString()}',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAddressRow(ThemeData theme, String address, BigInt? amount) {
    final abbreviated =
        address.length > 16
            ? '${address.substring(0, 8)}...${address.substring(address.length - 8)}'
            : address;
    final hasFunds = amount != null;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color:
            hasFunds
                ? theme.colorScheme.primary.withValues(alpha: 0.08)
                : theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color:
              hasFunds
                  ? theme.colorScheme.primary.withValues(alpha: 0.3)
                  : theme.colorScheme.primary.withValues(alpha: 0.15),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.account_balance_wallet_outlined,
            color: hasFunds ? theme.colorScheme.primary : Colors.grey,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              abbreviated,
              style: theme.textTheme.bodyMedium?.copyWith(letterSpacing: 0.5),
            ),
          ),
          if (hasFunds)
            Text(
              '${amount.toString()} sats',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
        ],
      ),
    );
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
    final showMsats = context.select<PreferencesProvider, bool>(
      (prefs) => prefs.showMsats,
    );

    // Prepare note and address previews
    final notePreview = _noteSummary?.take(5).toList() ?? [];
    final totalNotes =
        _noteSummary?.fold<int>(0, (sum, e) => sum + e.$2.toInt()) ?? 0;

    // Sort addresses: funded first
    final sortedAddresses =
        _addresses != null
            ? (List<(String, BigInt, BigInt?)>.from(_addresses!)..sort((a, b) {
              if (a.$3 != null && b.$3 == null) return -1;
              if (a.$3 == null && b.$3 != null) return 1;
              return 0;
            }))
            : <(String, BigInt, BigInt?)>[];
    final addressPreview = sortedAddresses.take(3).toList();
    final totalAddresses = sortedAddresses.length;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          children: [
            Text(context.l10n.myWallet),
            if (widget.fed.network != null)
              Text(
                '${widget.fed.federationName} · ${widget.fed.network}',
                style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
              )
            else
              Text(
                widget.fed.federationName,
                style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
              ),
          ],
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child:
            _isSummaryLoading && _isLoadingBalance
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  children: [
                    // Balance header
                    if (_isLoadingBalance)
                      const SizedBox(
                        height: 48,
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else
                      Column(
                        children: [
                          Text(
                            formatBalance(
                              _balanceMsats,
                              showMsats,
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

                    // Lightning Address
                    Center(child: _buildLightningAddressRow(theme)),

                    // Federation card
                    _buildSectionHeader(
                      theme,
                      context.l10n.federation,
                      _federationMeta?.guardians.length ?? 0,
                    ),
                    _buildFederationCard(theme),

                    // Deposit Addresses
                    _buildSectionHeader(
                      theme,
                      context.l10n.depositAddresses,
                      totalAddresses,
                      onViewAll:
                          totalAddresses > 0
                              ? () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder:
                                        (_) => Scaffold(
                                          appBar: AppBar(
                                            title: Text(
                                              context.l10n.depositAddresses,
                                            ),
                                          ),
                                          body: Padding(
                                            padding: const EdgeInsets.all(16),
                                            child: OnchainAddressesList(
                                              fed: widget.fed,
                                              updateAddresses:
                                                  widget.onAddressesUpdated ??
                                                  () {},
                                            ),
                                          ),
                                        ),
                                  ),
                                );
                              }
                              : null,
                    ),
                    if (addressPreview.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          context.l10n.noAddressesFound,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: Colors.grey,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      )
                    else
                      ...addressPreview.map((entry) {
                        final (address, _, amount) = entry;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _buildAddressRow(theme, address, amount),
                        );
                      }),

                    // Ecash Notes
                    _buildSectionHeader(
                      theme,
                      context.l10n.ecashNotes,
                      totalNotes,
                      onViewAll:
                          totalNotes > 0
                              ? () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder:
                                        (_) => Scaffold(
                                          appBar: AppBar(
                                            title: Text(
                                              context.l10n.ecashNotes,
                                            ),
                                          ),
                                          body: Padding(
                                            padding: const EdgeInsets.all(16),
                                            child: NoteSummary(fed: widget.fed),
                                          ),
                                        ),
                                  ),
                                );
                              }
                              : null,
                    ),
                    if (notePreview.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          context.l10n.noNotesAvailable,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: Colors.grey,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      )
                    else
                      ...notePreview.map((entry) {
                        final (denom, count) = entry;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _buildNoteRow(
                            theme,
                            denom,
                            count,
                            bitcoinDisplay,
                          ),
                        );
                      }),
                  ],
                ),
      ),
    );
  }
}
