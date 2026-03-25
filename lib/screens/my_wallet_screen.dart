import 'package:ecashapp/db.dart';
import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/providers/preferences_provider.dart';
import 'package:ecashapp/utils.dart';
import 'package:ecashapp/widgets/addresses.dart';
import 'package:ecashapp/widgets/note_summary.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

enum _WalletSection { addresses, notes }

class MyWalletScreen extends StatefulWidget {
  final FederationSelector fed;
  final VoidCallback? onAddressesUpdated;

  const MyWalletScreen({super.key, required this.fed, this.onAddressesUpdated});

  @override
  State<MyWalletScreen> createState() => _MyWalletScreenState();
}

class _MyWalletScreenState extends State<MyWalletScreen> {
  _WalletSection _selectedSection = _WalletSection.addresses;
  BigInt? _balanceMsats;
  bool _isLoadingBalance = true;
  bool _showMsats = false;
  Map<FiatCurrency, double> _btcPrices = {};
  bool _isLoadingPrices = true;

  @override
  void initState() {
    super.initState();
    _loadBalance();
    _loadBtcPrices();
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

  Widget _buildSectionChips(ThemeData theme) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
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

  Widget _buildSelectedContent() {
    switch (_selectedSection) {
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
