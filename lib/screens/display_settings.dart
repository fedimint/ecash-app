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
          Text(
            'Bitcoin Display',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.primary,
            ),
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
                  title: const Text('BIP177 (₿1,234)'),
                  value: BitcoinDisplay.bip177,
                  groupValue: _selectedBitcoinDisplay,
                  onChanged: (value) {
                    setState(() => _selectedBitcoinDisplay = value!);
                    _saveBitcoinDisplay(value!);
                  },
                ),
                const Divider(height: 1),
                RadioListTile<BitcoinDisplay>(
                  title: const Text('Sats are the Standard (1,234 sats)'),
                  value: BitcoinDisplay.sats,
                  groupValue: _selectedBitcoinDisplay,
                  onChanged: (value) {
                    setState(() => _selectedBitcoinDisplay = value!);
                    _saveBitcoinDisplay(value!);
                  },
                ),
                const Divider(height: 1),
                RadioListTile<BitcoinDisplay>(
                  title: const Text('Sat Symbol (1,234丰)'),
                  value: BitcoinDisplay.symbol,
                  groupValue: _selectedBitcoinDisplay,
                  onChanged: (value) {
                    setState(() => _selectedBitcoinDisplay = value!);
                    _saveBitcoinDisplay(value!);
                  },
                ),
                const Divider(height: 1),
                RadioListTile<BitcoinDisplay>(
                  title: const Text('No label (1,234)'),
                  value: BitcoinDisplay.nothing,
                  groupValue: _selectedBitcoinDisplay,
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
          Text(
            'Fiat Currency',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.primary,
            ),
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
                  title: const Text('US Dollar (\$)'),
                  value: FiatCurrency.usd,
                  groupValue: _selectedFiatCurrency,
                  onChanged: (value) {
                    setState(() => _selectedFiatCurrency = value!);
                    _saveFiatCurrency(value!);
                  },
                ),
                const Divider(height: 1),
                RadioListTile<FiatCurrency>(
                  title: const Text('Euro (€)'),
                  value: FiatCurrency.eur,
                  groupValue: _selectedFiatCurrency,
                  onChanged: (value) {
                    setState(() => _selectedFiatCurrency = value!);
                    _saveFiatCurrency(value!);
                  },
                ),
                const Divider(height: 1),
                RadioListTile<FiatCurrency>(
                  title: const Text('British Pound (£)'),
                  value: FiatCurrency.gbp,
                  groupValue: _selectedFiatCurrency,
                  onChanged: (value) {
                    setState(() => _selectedFiatCurrency = value!);
                    _saveFiatCurrency(value!);
                  },
                ),
                const Divider(height: 1),
                RadioListTile<FiatCurrency>(
                  title: const Text('Canadian Dollar (C\$)'),
                  value: FiatCurrency.cad,
                  groupValue: _selectedFiatCurrency,
                  onChanged: (value) {
                    setState(() => _selectedFiatCurrency = value!);
                    _saveFiatCurrency(value!);
                  },
                ),
                const Divider(height: 1),
                RadioListTile<FiatCurrency>(
                  title: const Text('Swiss Franc (CHF)'),
                  value: FiatCurrency.chf,
                  groupValue: _selectedFiatCurrency,
                  onChanged: (value) {
                    setState(() => _selectedFiatCurrency = value!);
                    _saveFiatCurrency(value!);
                  },
                ),
                const Divider(height: 1),
                RadioListTile<FiatCurrency>(
                  title: const Text('Australian Dollar (A\$)'),
                  value: FiatCurrency.aud,
                  groupValue: _selectedFiatCurrency,
                  onChanged: (value) {
                    setState(() => _selectedFiatCurrency = value!);
                    _saveFiatCurrency(value!);
                  },
                ),
                const Divider(height: 1),
                RadioListTile<FiatCurrency>(
                  title: const Text('Japanese Yen (¥)'),
                  value: FiatCurrency.jpy,
                  groupValue: _selectedFiatCurrency,
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
