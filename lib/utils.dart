import 'dart:io';

import 'package:ecashapp/db.dart';
import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

extension MilliSats on BigInt {
  BigInt get toSats => this ~/ BigInt.from(1000);
}

/// Render a deep link for logging without its payload.
///
/// A deep link routinely carries a one-time credential — an LNURLw `k1` is on
/// its own enough to claim a Boltcard withdrawal, and a `lightning:` link is a
/// full bolt11 invoice. Whoever reads the log would be racing the user for it,
/// so only the scheme and host are ever recorded.
String redactUriForLog(Uri uri) {
  final host = uri.host.isEmpty ? '' : '//${uri.host}';
  return '${uri.scheme}:$host<redacted ${uri.toString().length} chars>';
}

class AppLogger {
  /// Null until [init] runs — before that (and under `flutter test`, which has
  /// no app directories) logging degrades to console only. A diagnostic must
  /// never be the reason a caller dies, and a `late final` here meant any pure
  /// logic that logged could not be unit tested at all.
  static File? _logFile;
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
    final logFile = File('${dir!.path}/ecashapp/ecashapp.txt');

    if (!(await logFile.exists())) {
      await logFile.create(recursive: true);
    }
    _logFile = logFile;

    instance.info("Logger initialized. Log file: ${logFile.path}");
  }

  /// Roll over once the log passes this size, keeping one previous generation.
  /// Bounds on-disk history to ~2x this, so a leak that slips through has a
  /// finite lifetime instead of living in the file forever.
  static const int _maxLogBytes = 2 * 1024 * 1024;

  void _log(String level, String message) {
    final timestamp = DateTime.now().toIso8601String();
    final formatted = "[$timestamp] [$level] $message";

    // Print to console
    debugPrint(formatted);

    // Write to file
    final logFile = _logFile;
    if (logFile == null) return;
    _rotateIfOversized();
    logFile.writeAsStringSync(
      "$formatted\n",
      mode: FileMode.append,
      flush: true,
    );
  }

  void _rotateIfOversized() {
    final logFile = _logFile;
    if (logFile == null) return;
    try {
      if (!logFile.existsSync() || logFile.lengthSync() < _maxLogBytes) {
        return;
      }
      final previous = File('${logFile.path}.1');
      if (previous.existsSync()) {
        previous.deleteSync();
      }
      logFile.renameSync(previous.path);
      logFile.createSync(recursive: true);
    } catch (_) {
      // Rotation is best-effort; never let it break logging itself.
    }
  }

  /// Delete the log and its rotated generation. Exposed so the user can clear
  /// history without hunting for the file on disk.
  Future<void> clear() async {
    final logFile = _logFile;
    if (logFile == null) return;
    try {
      final previous = File('${logFile.path}.1');
      if (await previous.exists()) {
        await previous.delete();
      }
      if (await logFile.exists()) {
        await logFile.delete();
      }
      await logFile.create(recursive: true);
    } catch (e) {
      debugPrint('Could not clear log file: $e');
    }
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
    final logFile = _logFile;
    if (logFile == null) return;
    logFile.writeAsStringSync(
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

  final formattedValue = NumberFormat('#,##0.00', 'en_US').format(fiatValue);
  return symbolPosition == 'before'
      ? '$symbol$formattedValue'
      : '$formattedValue$symbol';
}

/// Groups a run of digits with a comma every three places, so fiat amounts
/// read as easily as the space-grouped sats amounts from [formatBalance].
String _groupDigits(String digits) {
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return buffer.toString();
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
    // Group the integer part, but show decimals as-is during typing
    formattedValue = '${_groupDigits(intPart)}.$decPart';
  } else {
    formattedValue = _groupDigits(rawFiatInput);
  }

  return symbolPosition == 'before'
      ? '$symbol$formattedValue'
      : '$formattedValue$symbol';
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

/// Asks the user to approve an action that reaches a third party, returning
/// whether they agreed.
///
/// Dismissing the dialog returns false, so the caller only proceeds on an
/// explicit yes — never on a back gesture or a tap outside.
Future<bool> confirmExternalRequest(
  BuildContext context, {
  required String title,
  required String body,
  required String confirmLabel,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder:
        (context) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(context.l10n.cancel),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(confirmLabel),
            ),
          ],
        ),
  );

  return confirmed == true;
}

Future<void> showExplorerConfirmation(BuildContext context, Uri url) async {
  final confirmed = await confirmExternalRequest(
    context,
    title: context.l10n.externalLinkWarning,
    body: context.l10n.externalLinkBody,
    confirmLabel: context.l10n.confirm,
  );

  if (confirmed && await canLaunchUrl(url)) {
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
