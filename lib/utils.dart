import 'dart:io';

import 'package:ecashapp/db.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/models.dart';
import 'package:ecashapp/multimint.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

extension MilliSats on BigInt {
  BigInt get toSats => this ~/ BigInt.from(1000);
}

class AppLogger {
  static late final File _logFile;
  static final AppLogger instance = AppLogger._internal();

  AppLogger._internal();

  static Future<void> init() async {
    Directory? dir;
    if (Platform.isAndroid) {
      dir = await getExternalStorageDirectory();
    } else if (Platform.isLinux) {
      final appName = kDebugMode ? 'ecash-app-dev' : 'ecash-app';
      final homeDir = Platform.environment['HOME']!;
      dir = Directory('$homeDir/.local/share/$appName');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
    } else {
      dir = await getApplicationDocumentsDirectory();
    }
    _logFile = File('${dir!.path}/ecashapp/ecashapp.txt');

    if (!(await _logFile.exists())) {
      await _logFile.create(recursive: true);
    }

    instance.info("Logger initialized. Log file: ${_logFile.path}");
  }

  void _log(String level, String message) {
    final timestamp = DateTime.now().toIso8601String();
    final formatted = "[$timestamp] [$level] $message";

    // Print to console
    debugPrint(formatted);

    // Write to file
    _logFile.writeAsStringSync(
      "$formatted\n",
      mode: FileMode.append,
      flush: true,
    );
  }

  void _rustLog(LogLevel level, String message) {
    String logLevel;
    switch (level) {
      case LogLevel.trace:
        logLevel = "TRACE";
        break;
      case LogLevel.error:
        logLevel = "ERROR";
        break;
      case LogLevel.info:
        logLevel = "INFO";
        break;
      case LogLevel.debug:
        logLevel = "DEBUG";
        break;
      case LogLevel.warn:
        logLevel = "WARN";
        break;
    }

    final timestamp = DateTime.now().toIso8601String();
    final formatted = "[$timestamp] [RUST] [$logLevel] $message";

    // Print to console
    debugPrint(formatted);

    // Write to file
    _logFile.writeAsStringSync(
      "$formatted\n",
      mode: FileMode.append,
      flush: true,
    );
  }

  void info(String message) => _log("INFO", message);
  void warn(String message) => _log("WARN", message);
  void error(String message) => _log("ERROR", message);
  void debug(String message) => _log("DEBUG", message);
  void rustLog(LogLevel level, String message) => _rustLog(level, message);
}

int threshold(int totalPeers) {
  final maxEvil = (totalPeers - 1) ~/ 3;
  return totalPeers - maxEvil;
}

String formatBalance(
  BigInt? msats,
  bool showMsats,
  BitcoinDisplay bitcoinDisplay,
) {
  final setting = bitcoinDisplay;

  if (msats == null) {
    return switch (setting) {
      BitcoinDisplay.bip177 => showMsats ? '₿0.000' : '₿0',
      BitcoinDisplay.sats => showMsats ? '0.000 sats' : '0 sats',
      BitcoinDisplay.nothing => showMsats ? '0.000' : '0',
      BitcoinDisplay.symbol => showMsats ? '0.000丰' : '0丰',
    };
  }

  if (showMsats) {
    final btcAmount = msats.toDouble() / 1000;
    final formatter = NumberFormat('#,##0.000', 'en_US');
    var formatted = formatter.format(btcAmount).replaceAll(',', ' ');
    return switch (setting) {
      BitcoinDisplay.bip177 => '₿$formatted',
      BitcoinDisplay.sats => '$formatted sats',
      BitcoinDisplay.nothing => formatted,
      BitcoinDisplay.symbol => '$formatted丰',
    };
  } else {
    final sats = msats.toSats;
    final formatter = NumberFormat('#,##0', 'en_US');
    var formatted = formatter.format(sats.toInt()).replaceAll(',', ' ');
    return switch (setting) {
      BitcoinDisplay.bip177 => '₿$formatted',
      BitcoinDisplay.sats => '$formatted sats',
      BitcoinDisplay.nothing => formatted,
      BitcoinDisplay.symbol => '$formatted丰',
    };
  }
}

String getAbbreviatedText(String text) {
  if (text.length <= 14) return text;
  return '${text.substring(0, 7)}...${text.substring(text.length - 7)}';
}

String calculateFiatValue(
  double? btcPrice,
  int sats,
  FiatCurrency fiatCurrency,
) {
  if (btcPrice == null) return '';

  // btcPrice is fetched from mempool.space API for the specific currency
  final fiatValue = (btcPrice * sats) / 100000000;

  // Get currency symbol and format
  final (symbol, symbolPosition) = switch (fiatCurrency) {
    FiatCurrency.usd => ('\$', 'before'),
    FiatCurrency.eur => ('€', 'after'),
    FiatCurrency.gbp => ('£', 'before'),
    FiatCurrency.cad => ('C\$', 'before'),
    FiatCurrency.chf => ('CHF ', 'before'),
    FiatCurrency.aud => ('A\$', 'before'),
    FiatCurrency.jpy => ('¥', 'before'),
  };

  final formattedValue = fiatValue.toStringAsFixed(2);
  return symbolPosition == 'before'
      ? '$symbol$formattedValue'
      : '$formattedValue$symbol';
}

/// Converts a fiat amount to satoshis based on the current BTC price.
/// Returns 0 if btcPrice is null or zero to avoid division errors.
///
/// Formula: sats = (fiatValue * 100000000) / btcPrice
int calculateSatsFromFiat(double? btcPrice, double fiatAmount) {
  if (btcPrice == null || btcPrice == 0) return 0;
  return ((fiatAmount * 100000000) / btcPrice).round();
}

/// Formats a raw fiat input string for display with currency symbol.
/// Handles partial input like "12." or "12.5" during typing.
String formatFiatInput(String rawFiatInput, FiatCurrency fiatCurrency) {
  if (rawFiatInput.isEmpty) rawFiatInput = '0';

  final (symbol, symbolPosition) = switch (fiatCurrency) {
    FiatCurrency.usd => ('\$', 'before'),
    FiatCurrency.eur => ('€', 'after'),
    FiatCurrency.gbp => ('£', 'before'),
    FiatCurrency.cad => ('C\$', 'before'),
    FiatCurrency.chf => ('CHF ', 'before'),
    FiatCurrency.aud => ('A\$', 'before'),
    FiatCurrency.jpy => ('¥', 'before'),
  };

  // Handle partial decimal input (user typed "12." or "12.5")
  String formattedValue;
  if (rawFiatInput.contains('.')) {
    final parts = rawFiatInput.split('.');
    final intPart = parts[0].isEmpty ? '0' : parts[0];
    final decPart = parts.length > 1 ? parts[1] : '';
    // Show as-is during typing, don't pad decimals
    formattedValue = '$intPart.$decPart';
  } else {
    formattedValue = rawFiatInput;
  }

  return symbolPosition == 'before'
      ? '$symbol$formattedValue'
      : '$formattedValue$symbol';
}

int getModuleIdForPaymentType(PaymentType paymentType) {
  switch (paymentType) {
    case PaymentType.lightning:
      return 0;
    case PaymentType.ecash:
      return 1;
    case PaymentType.onchain:
      return 2;
  }
}

Future<Map<FiatCurrency, double>> fetchAllBtcPrices() async {
  try {
    final pricesList = await getAllBtcPrices();
    if (pricesList == null) {
      AppLogger.instance.warn("getAllBtcPrices returned null");
      return {};
    }

    // Convert List of tuples to Map
    final result = <FiatCurrency, double>{};
    for (final entry in pricesList) {
      result[entry.$1] = entry.$2.toDouble();
    }
    return result;
  } catch (e) {
    AppLogger.instance.error("Error fetching all prices: $e");
    return {};
  }
}

String? explorerUrlForNetwork(String txid, String? network) {
  switch (network) {
    case 'bitcoin':
      return 'https://mempool.space/tx/$txid';
    case 'signet':
      return 'https://mutinynet.com/tx/$txid';
    default:
      return null;
  }
}

Future<void> showExplorerConfirmation(BuildContext context, Uri url) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder:
        (context) => AlertDialog(
          title: const Text('External Link Warning'),
          content: const Text(
            'You are about to navigate to an external block explorer. '
            'Before accepting, please consider the privacy implications '
            'and consider using a self hosted block explorer.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Confirm'),
            ),
          ],
        ),
  );

  if (confirmed == true && await canLaunchUrl(url)) {
    await launchUrl(url, mode: LaunchMode.externalApplication);
  }
}

bool isValidRelayUri(String input) {
  if (input.isEmpty) return false;
  try {
    final uri = Uri.parse(input);
    return (uri.scheme == 'wss' || uri.scheme == 'ws') && uri.hasAuthority;
  } catch (_) {
    return false;
  }
}

bool get isMobile {
  return defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android ||
      kIsWeb;
}
