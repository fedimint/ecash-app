import 'package:ecashapp/db.dart';
import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/providers/preferences_provider.dart';
import 'package:ecashapp/toast.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class DisplaySettingsScreen extends StatefulWidget {
  const DisplaySettingsScreen({super.key});

  @override
  State<DisplaySettingsScreen> createState() => _DisplaySettingsScreenState();
}

class _DisplaySettingsScreenState extends State<DisplaySettingsScreen> {
  late BitcoinDisplay _selectedBitcoinDisplay;
  late FiatCurrency _selectedFiatCurrency;
  late bool _selectedShowMsats;
  late BitcoinDisplay _initialBitcoinDisplay;
  late FiatCurrency _initialFiatCurrency;
  late bool _initialShowMsats;

  @override
  void initState() {
    super.initState();
    final preferencesProvider = context.read<PreferencesProvider>();
    _selectedBitcoinDisplay = preferencesProvider.bitcoinDisplay;
    _selectedFiatCurrency = preferencesProvider.fiatCurrency;
    _selectedShowMsats = preferencesProvider.showMsats;
    _initialBitcoinDisplay = preferencesProvider.bitcoinDisplay;
    _initialFiatCurrency = preferencesProvider.fiatCurrency;
    _initialShowMsats = preferencesProvider.showMsats;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.displaySettings),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _handleBackNavigation,
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Bitcoin Display Section
          Row(
            children: [
              Icon(
                Icons.currency_bitcoin,
                color: theme.colorScheme.primary,
                size: 28,
              ),
              const SizedBox(width: 12),
              Text(
                context.l10n.bitcoinDisplay,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Card(
            elevation: 2,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                RadioListTile<BitcoinDisplay>(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  title: Text(
                    context.l10n.bip177Option,
                    style: TextStyle(
                      fontWeight:
                          _selectedBitcoinDisplay == BitcoinDisplay.bip177
                              ? FontWeight.w600
                              : FontWeight.normal,
                      color:
                          _selectedBitcoinDisplay == BitcoinDisplay.bip177
                              ? theme.colorScheme.primary
                              : null,
                    ),
                  ),
                  subtitle: Text(
                    context.l10n.bip177Description,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  value: BitcoinDisplay.bip177,
                  groupValue: _selectedBitcoinDisplay,
                  activeColor: theme.colorScheme.primary,
                  onChanged: (value) {
                    setState(() => _selectedBitcoinDisplay = value!);
                    _saveBitcoinDisplay(value!);
                  },
                ),
                RadioListTile<BitcoinDisplay>(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  title: Text(
                    context.l10n.satsStandardOption,
                    style: TextStyle(
                      fontWeight:
                          _selectedBitcoinDisplay == BitcoinDisplay.sats
                              ? FontWeight.w600
                              : FontWeight.normal,
                      color:
                          _selectedBitcoinDisplay == BitcoinDisplay.sats
                              ? theme.colorScheme.primary
                              : null,
                    ),
                  ),
                  subtitle: Text(
                    context.l10n.satsStandardDescription,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  value: BitcoinDisplay.sats,
                  groupValue: _selectedBitcoinDisplay,
                  activeColor: theme.colorScheme.primary,
                  onChanged: (value) {
                    setState(() => _selectedBitcoinDisplay = value!);
                    _saveBitcoinDisplay(value!);
                  },
                ),
                RadioListTile<BitcoinDisplay>(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  title: Text(
                    context.l10n.satSymbolOption,
                    style: TextStyle(
                      fontWeight:
                          _selectedBitcoinDisplay == BitcoinDisplay.symbol
                              ? FontWeight.w600
                              : FontWeight.normal,
                      color:
                          _selectedBitcoinDisplay == BitcoinDisplay.symbol
                              ? theme.colorScheme.primary
                              : null,
                    ),
                  ),
                  subtitle: Text(
                    context.l10n.satSymbolDescription,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  value: BitcoinDisplay.symbol,
                  groupValue: _selectedBitcoinDisplay,
                  activeColor: theme.colorScheme.primary,
                  onChanged: (value) {
                    setState(() => _selectedBitcoinDisplay = value!);
                    _saveBitcoinDisplay(value!);
                  },
                ),
                RadioListTile<BitcoinDisplay>(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  title: Text(
                    context.l10n.noLabelOption,
                    style: TextStyle(
                      fontWeight:
                          _selectedBitcoinDisplay == BitcoinDisplay.nothing
                              ? FontWeight.w600
                              : FontWeight.normal,
                      color:
                          _selectedBitcoinDisplay == BitcoinDisplay.nothing
                              ? theme.colorScheme.primary
                              : null,
                    ),
                  ),
                  subtitle: Text(
                    context.l10n.noLabelDescription,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  value: BitcoinDisplay.nothing,
                  groupValue: _selectedBitcoinDisplay,
                  activeColor: theme.colorScheme.primary,
                  onChanged: (value) {
                    setState(() => _selectedBitcoinDisplay = value!);
                    _saveBitcoinDisplay(value!);
                  },
                ),
              ],
            ),
          ),

          const SizedBox(height: 32),

          // Show Millisatoshis Section
          Card(
            elevation: 2,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: SwitchListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 8,
              ),
              secondary: Icon(
                Icons.precision_manufacturing_outlined,
                color: theme.colorScheme.primary,
                size: 28,
              ),
              title: Text(
                context.l10n.showMillisatoshis,
                style: TextStyle(
                  fontWeight:
                      _selectedShowMsats ? FontWeight.w600 : FontWeight.normal,
                  color: _selectedShowMsats ? theme.colorScheme.primary : null,
                ),
              ),
              subtitle: Text(
                context.l10n.showMillisatoshisDescription,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              value: _selectedShowMsats,
              activeThumbColor: theme.colorScheme.primary,
              onChanged: (value) {
                setState(() => _selectedShowMsats = value);
                _saveShowMsats(value);
              },
            ),
          ),

          const SizedBox(height: 32),

          // Fiat Currency Section
          Row(
            children: [
              Icon(
                Icons.attach_money,
                color: theme.colorScheme.primary,
                size: 28,
              ),
              const SizedBox(width: 12),
              Text(
                context.l10n.fiatCurrency,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Card(
            elevation: 2,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                RadioListTile<FiatCurrency>(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  title: Text(
                    context.l10n.usDollar,
                    style: TextStyle(
                      fontWeight:
                          _selectedFiatCurrency == FiatCurrency.usd
                              ? FontWeight.w600
                              : FontWeight.normal,
                      color:
                          _selectedFiatCurrency == FiatCurrency.usd
                              ? theme.colorScheme.primary
                              : null,
                    ),
                  ),
                  subtitle: Text(
                    context.l10n.unitedStates,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  value: FiatCurrency.usd,
                  groupValue: _selectedFiatCurrency,
                  activeColor: theme.colorScheme.primary,
                  onChanged: (value) {
                    setState(() => _selectedFiatCurrency = value!);
                    _saveFiatCurrency(value!);
                  },
                ),
                RadioListTile<FiatCurrency>(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  title: Text(
                    context.l10n.euro,
                    style: TextStyle(
                      fontWeight:
                          _selectedFiatCurrency == FiatCurrency.eur
                              ? FontWeight.w600
                              : FontWeight.normal,
                      color:
                          _selectedFiatCurrency == FiatCurrency.eur
                              ? theme.colorScheme.primary
                              : null,
                    ),
                  ),
                  subtitle: Text(
                    context.l10n.europeanUnion,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  value: FiatCurrency.eur,
                  groupValue: _selectedFiatCurrency,
                  activeColor: theme.colorScheme.primary,
                  onChanged: (value) {
                    setState(() => _selectedFiatCurrency = value!);
                    _saveFiatCurrency(value!);
                  },
                ),
                RadioListTile<FiatCurrency>(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  title: Text(
                    context.l10n.britishPound,
                    style: TextStyle(
                      fontWeight:
                          _selectedFiatCurrency == FiatCurrency.gbp
                              ? FontWeight.w600
                              : FontWeight.normal,
                      color:
                          _selectedFiatCurrency == FiatCurrency.gbp
                              ? theme.colorScheme.primary
                              : null,
                    ),
                  ),
                  subtitle: Text(
                    context.l10n.unitedKingdom,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  value: FiatCurrency.gbp,
                  groupValue: _selectedFiatCurrency,
                  activeColor: theme.colorScheme.primary,
                  onChanged: (value) {
                    setState(() => _selectedFiatCurrency = value!);
                    _saveFiatCurrency(value!);
                  },
                ),
                RadioListTile<FiatCurrency>(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  title: Text(
                    context.l10n.canadianDollar,
                    style: TextStyle(
                      fontWeight:
                          _selectedFiatCurrency == FiatCurrency.cad
                              ? FontWeight.w600
                              : FontWeight.normal,
                      color:
                          _selectedFiatCurrency == FiatCurrency.cad
                              ? theme.colorScheme.primary
                              : null,
                    ),
                  ),
                  subtitle: Text(
                    context.l10n.canada,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  value: FiatCurrency.cad,
                  groupValue: _selectedFiatCurrency,
                  activeColor: theme.colorScheme.primary,
                  onChanged: (value) {
                    setState(() => _selectedFiatCurrency = value!);
                    _saveFiatCurrency(value!);
                  },
                ),
                RadioListTile<FiatCurrency>(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  title: Text(
                    context.l10n.swissFranc,
                    style: TextStyle(
                      fontWeight:
                          _selectedFiatCurrency == FiatCurrency.chf
                              ? FontWeight.w600
                              : FontWeight.normal,
                      color:
                          _selectedFiatCurrency == FiatCurrency.chf
                              ? theme.colorScheme.primary
                              : null,
                    ),
                  ),
                  subtitle: Text(
                    context.l10n.switzerland,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  value: FiatCurrency.chf,
                  groupValue: _selectedFiatCurrency,
                  activeColor: theme.colorScheme.primary,
                  onChanged: (value) {
                    setState(() => _selectedFiatCurrency = value!);
                    _saveFiatCurrency(value!);
                  },
                ),
                RadioListTile<FiatCurrency>(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  title: Text(
                    context.l10n.australianDollar,
                    style: TextStyle(
                      fontWeight:
                          _selectedFiatCurrency == FiatCurrency.aud
                              ? FontWeight.w600
                              : FontWeight.normal,
                      color:
                          _selectedFiatCurrency == FiatCurrency.aud
                              ? theme.colorScheme.primary
                              : null,
                    ),
                  ),
                  subtitle: Text(
                    context.l10n.australia,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  value: FiatCurrency.aud,
                  groupValue: _selectedFiatCurrency,
                  activeColor: theme.colorScheme.primary,
                  onChanged: (value) {
                    setState(() => _selectedFiatCurrency = value!);
                    _saveFiatCurrency(value!);
                  },
                ),
                RadioListTile<FiatCurrency>(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  title: Text(
                    context.l10n.japaneseYen,
                    style: TextStyle(
                      fontWeight:
                          _selectedFiatCurrency == FiatCurrency.jpy
                              ? FontWeight.w600
                              : FontWeight.normal,
                      color:
                          _selectedFiatCurrency == FiatCurrency.jpy
                              ? theme.colorScheme.primary
                              : null,
                    ),
                  ),
                  subtitle: Text(
                    context.l10n.japan,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  value: FiatCurrency.jpy,
                  groupValue: _selectedFiatCurrency,
                  activeColor: theme.colorScheme.primary,
                  onChanged: (value) {
                    setState(() => _selectedFiatCurrency = value!);
                    _saveFiatCurrency(value!);
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  bool _hasSettingsChanged() {
    return _selectedBitcoinDisplay != _initialBitcoinDisplay ||
        _selectedFiatCurrency != _initialFiatCurrency ||
        _selectedShowMsats != _initialShowMsats;
  }

  void _handleBackNavigation() {
    if (_hasSettingsChanged()) {
      ToastService().show(
        message: context.l10n.displaySettingsUpdated,
        duration: const Duration(seconds: 2),
        onTap: () {},
        icon: const Icon(Icons.check),
      );
    }
    Navigator.pop(context);
  }

  Future<void> _saveBitcoinDisplay(BitcoinDisplay display) async {
    final preferencesProvider = context.read<PreferencesProvider>();
    await preferencesProvider.setBitcoinDisplay(display);
  }

  Future<void> _saveFiatCurrency(FiatCurrency currency) async {
    final preferencesProvider = context.read<PreferencesProvider>();
    await preferencesProvider.setFiatCurrency(currency);
  }

  Future<void> _saveShowMsats(bool value) async {
    final preferencesProvider = context.read<PreferencesProvider>();
    await preferencesProvider.setShowMsats(value);
  }
}
