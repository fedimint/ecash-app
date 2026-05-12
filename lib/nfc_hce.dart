import 'dart:io';

import 'package:ecashapp/utils.dart';
import 'package:flutter/services.dart';

class InvoiceNfcBroadcaster {
  static const _channel = MethodChannel('ecashapp/nfc_hce');

  static Future<bool> isAvailable() async {
    if (!Platform.isAndroid) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('isAvailable') ?? false;
      AppLogger.instance.info("HCE: available=$ok");
      return ok;
    } catch (e) {
      AppLogger.instance.warn("HCE: availability check failed: $e");
      return false;
    }
  }

  static Future<void> start(String invoice) async {
    final payload =
        invoice.toLowerCase().startsWith('lightning:')
            ? invoice
            : 'lightning:$invoice';
    AppLogger.instance.info("HCE: starting (len=${payload.length})");
    try {
      await _channel.invokeMethod('start', {'payload': payload});
    } catch (e) {
      AppLogger.instance.warn("HCE: start failed: $e");
      rethrow;
    }
  }

  static Future<void> stop() async {
    try {
      await _channel.invokeMethod('stop');
      AppLogger.instance.info("HCE: stopped");
    } catch (e) {
      AppLogger.instance.warn("HCE: stop failed: $e");
    }
  }
}
