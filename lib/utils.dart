import 'dart:io';

import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';

extension MilliSats on BigInt {
  BigInt get toSats => this ~/ BigInt.from(1000);
}

Future<void> logToFile(String message) async {
  final directory = await getExternalStorageDirectory();
  final file = File('${directory!.path}/log.txt');
  final timestamp = DateTime.now().toIso8601String();
  await file.writeAsString('[$timestamp] $message\n', mode: FileMode.append);
  print(message);
}

int threshold(int totalPeers) {
  final maxEvil = (totalPeers - 1) ~/ 3;
  return totalPeers - maxEvil;
}

String formatBalance(BigInt? msats, bool showMsats) {
  if (msats == null) return showMsats ? '0 msats' : '0 sats';

  if (showMsats) {
    final formatter = NumberFormat('#,##0', 'en_US');
    var formatted = formatter.format(msats.toInt());
    formatted = formatted.replaceAll(',', ' ');
    return '$formatted msats';
  } else {
    final sats = msats.toSats;
    final formatter = NumberFormat('#,##0', 'en_US');
    var formatted = formatter.format(sats.toInt());
    formatted = formatted.replaceAll(',', ' ');
    return '$formatted sats';
  }
}

String getAbbreviatedInvoice(String invoice) {
  if (invoice.length <= 14) return invoice;
  return '${invoice.substring(0, 7)}...${invoice.substring(invoice.length - 7)}';
}
