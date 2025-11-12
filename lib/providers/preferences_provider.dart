import 'package:ecashapp/db.dart';
import 'package:ecashapp/lib.dart' as rust_lib;
import 'package:ecashapp/utils.dart';
import 'package:flutter/foundation.dart';

class PreferencesProvider extends ChangeNotifier {
  BitcoinDisplay _bitcoinDisplay = BitcoinDisplay.bip177;
  FiatCurrency _fiatCurrency = FiatCurrency.usd;
  bool _isLoading = true;

  BitcoinDisplay get bitcoinDisplay => _bitcoinDisplay;
  FiatCurrency get fiatCurrency => _fiatCurrency;
  bool get isLoading => _isLoading;

  PreferencesProvider() {
    _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    try {
      _bitcoinDisplay = await rust_lib.getBitcoinDisplay();
      _fiatCurrency = await rust_lib.getFiatCurrency();
      _isLoading = false;
      notifyListeners();
    } catch (e) {
      AppLogger.instance.error('Failed to load preferences: $e');
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> setBitcoinDisplay(BitcoinDisplay display) async {
    _bitcoinDisplay = display;
    notifyListeners();
    try {
      await rust_lib.setBitcoinDisplay(bitcoinDisplay: display);
    } catch (e) {
      AppLogger.instance.error('Failed to save bitcoin display preference: $e');
    }
  }

  Future<void> setFiatCurrency(FiatCurrency currency) async {
    _fiatCurrency = currency;
    notifyListeners();
    try {
      await rust_lib.setFiatCurrency(fiatCurrency: currency);
    } catch (e) {
      AppLogger.instance.error('Failed to save fiat currency preference: $e');
    }
  }
}
