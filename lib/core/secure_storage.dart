import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Flutter Secure Storage for Android
AndroidOptions _getAndroidOptions() => const AndroidOptions(encryptedSharedPreferences: true);
final flutterSecureStorage = FlutterSecureStorage(aOptions: _getAndroidOptions());

class SecureStorageKeys {
  static const String selectedFederation = 'selected_federation';
}
