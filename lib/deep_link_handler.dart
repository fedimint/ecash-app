import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:ecashapp/utils.dart';

enum DeepLinkType {
  lightning,
  lnurl,
  bitcoin,
}

class DeepLinkData {
  final DeepLinkType type;
  final String data;

  DeepLinkData({required this.type, required this.data});

  @override
  String toString() => 'DeepLinkData(type: $type, data: $data)';
}

class DeepLinkHandler {
  static final DeepLinkHandler _instance = DeepLinkHandler._internal();
  factory DeepLinkHandler() => _instance;
  DeepLinkHandler._internal();

  late final AppLinks _appLinks;
  DeepLinkData? _pendingDeepLink;
  StreamSubscription<Uri>? _subscription;

  final StreamController<DeepLinkData> _deepLinkController =
      StreamController<DeepLinkData>.broadcast();

  Stream<DeepLinkData> get deepLinkStream => _deepLinkController.stream;

  DeepLinkData? get pendingDeepLink => _pendingDeepLink;

  void clearPendingDeepLink() {
    _pendingDeepLink = null;
  }

  Future<void> init() async {
    _appLinks = AppLinks();

    // Check for initial link (cold start)
    try {
      final initialUri = await _appLinks.getInitialLink();
      if (initialUri != null) {
        AppLogger.instance.info('Deep link cold start: $initialUri');
        final deepLinkData = _parseUri(initialUri);
        if (deepLinkData != null) {
          _pendingDeepLink = deepLinkData;
        }
      }
    } catch (e) {
      AppLogger.instance.error('Error getting initial deep link: $e');
    }

    // Listen for warm start links
    _subscription = _appLinks.uriLinkStream.listen((uri) {
      AppLogger.instance.info('Deep link warm start: $uri');
      final deepLinkData = _parseUri(uri);
      if (deepLinkData != null) {
        _deepLinkController.add(deepLinkData);
      }
    }, onError: (e) {
      AppLogger.instance.error('Error listening to deep links: $e');
    });
  }

  DeepLinkData? _parseUri(Uri uri) {
    final scheme = uri.scheme.toLowerCase();

    if (scheme == 'lightning') {
      // lightning:lnbc1... -> extract the invoice
      // The data can be in the host, path, or the entire schemeSpecificPart
      String data = uri.host.isNotEmpty
          ? uri.host + uri.path
          : uri.path.isNotEmpty
              ? uri.path
              : uri.toString().substring('lightning:'.length);

      // Remove any leading slashes
      data = data.replaceFirst(RegExp(r'^/+'), '');

      if (data.isNotEmpty) {
        AppLogger.instance.info('Parsed lightning invoice: ${data.substring(0, data.length > 20 ? 20 : data.length)}...');
        return DeepLinkData(type: DeepLinkType.lightning, data: data);
      }
    } else if (scheme == 'lnurl' || scheme == 'lnurlp' || scheme == 'lnurlw') {
      // lnurl:LNURL1... / lnurlp:LNURL1... / lnurlw:LNURL1... -> extract the LNURL
      final schemePrefix = '$scheme:';
      String data = uri.host.isNotEmpty
          ? uri.host + uri.path
          : uri.path.isNotEmpty
              ? uri.path
              : uri.toString().substring(schemePrefix.length);

      // Remove any leading slashes
      data = data.replaceFirst(RegExp(r'^/+'), '');

      if (data.isNotEmpty) {
        AppLogger.instance.info('Parsed LNURL ($scheme): ${data.substring(0, data.length > 20 ? 20 : data.length)}...');
        return DeepLinkData(type: DeepLinkType.lnurl, data: data);
      }
    } else if (scheme == 'bitcoin') {
      // bitcoin:bc1q...?amount=0.001 -> extract address and query params
      // The Rust parser handles the full BIP21 URI, so we pass the whole thing
      String data = uri.toString().substring('bitcoin:'.length);

      // Remove any leading slashes
      data = data.replaceFirst(RegExp(r'^/+'), '');

      if (data.isNotEmpty) {
        AppLogger.instance.info('Parsed Bitcoin address: ${data.substring(0, data.length > 20 ? 20 : data.length)}...');
        return DeepLinkData(type: DeepLinkType.bitcoin, data: data);
      }
    }

    AppLogger.instance.warn('Unknown deep link scheme: $scheme');
    return null;
  }

  void dispose() {
    _subscription?.cancel();
    _deepLinkController.close();
  }
}
