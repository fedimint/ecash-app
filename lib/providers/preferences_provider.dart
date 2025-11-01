import 'package:ecashapp/db.dart';
import 'package:ecashapp/lib.dart' as rust_lib;
import 'package:flutter/foundation.dart';

class PreferencesProvider extends ChangeNotifier {
  BitcoinDisplay _bitcoinDisplay = BitcoinDisplay.bip177;
  bool _isLoading = true;

  BitcoinDisplay get bitcoinDisplay => _bitcoinDisplay;
  bool get isLoading => _isLoading;

  PreferencesProvider() {
    _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    try {
      _bitcoinDisplay = await rust_lib.getBitcoinDisplay();
      _isLoading = false;
      notifyListeners();
    } catch (e) {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> setBitcoinDisplay(BitcoinDisplay display) async {
    _bitcoinDisplay = display;
    notifyListeners();
    await rust_lib.setBitcoinDisplay(bitcoinDisplay: display);
  }
}
