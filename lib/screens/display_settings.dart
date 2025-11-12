import 'package:ecashapp/db.dart';
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

  @override
  void initState() {
    super.initState();
    final preferencesProvider = context.read<PreferencesProvider>();
    _selectedBitcoinDisplay = preferencesProvider.bitcoinDisplay;
    _selectedFiatCurrency = preferencesProvider.fiatCurrency;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Display Settings')),
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
                'Bitcoin Display',
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
                    'BIP177 (₿1,234)',
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
                    'Bitcoin symbol with decimal places',
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
                    'Sats are the Standard (1,234 sats)',
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
                    'Display amounts in satoshis with "sats" label',
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
                    'Sat Symbol (1,234丰)',
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
                    'Use the satoshi symbol (丰) suffix',
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
                    'No label (1,234)',
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
                    'Plain numbers without currency indicators',
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
                'Fiat Currency',
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
                    'US Dollar (\$)',
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
                    'United States',
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
                    'Euro (€)',
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
                    'European Union',
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
                    'British Pound (£)',
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
                    'United Kingdom',
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
                    'Canadian Dollar (C\$)',
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
                    'Canada',
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
                    'Swiss Franc (CHF)',
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
                    'Switzerland',
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
                    'Australian Dollar (A\$)',
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
                    'Australia',
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
                    'Japanese Yen (¥)',
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
                    'Japan',
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

  Future<void> _saveBitcoinDisplay(BitcoinDisplay display) async {
    final preferencesProvider = context.read<PreferencesProvider>();
    await preferencesProvider.setBitcoinDisplay(display);
    ToastService().show(
      message: "Bitcoin display updated!",
      duration: const Duration(seconds: 2),
      onTap: () {},
      icon: const Icon(Icons.check),
    );
  }

  Future<void> _saveFiatCurrency(FiatCurrency currency) async {
    final preferencesProvider = context.read<PreferencesProvider>();
    await preferencesProvider.setFiatCurrency(currency);
    ToastService().show(
      message: "Fiat currency updated!",
      duration: const Duration(seconds: 2),
      onTap: () {},
      icon: const Icon(Icons.check),
    );
  }
}
