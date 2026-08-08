import 'dart:io';

import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const MethodChannel _channel = MethodChannel('ecashapp/secure_screen');

/// How many [SecureScreen]s are currently mounted.
///
/// Screens stack — the ecash send sheet can sit under a PIN dialog, the seed
/// view under a confirmation — and each one disposing must not clear the flag
/// while another still needs it. Only the first request turns it on and only
/// the last one turns it off.
int _activeRequests = 0;

Future<void> _setSecure(bool secure) async {
  // Android-only: FLAG_SECURE is a Window flag with no desktop equivalent, and
  // the channel is registered by MainActivity. Calling it elsewhere would throw
  // MissingPluginException.
  if (!Platform.isAndroid) return;
  try {
    await _channel.invokeMethod(secure ? 'enable' : 'disable');
  } catch (e) {
    // Never let screen hardening break the screen it is protecting.
    AppLogger.instance.warn('Could not set secure screen flag: $e');
  }
}

/// Marks its subtree as too sensitive to leave the device's screen.
///
/// While mounted the window carries `FLAG_SECURE`, which blocks screenshots and
/// screen recording and — the part that matters most — stops the OS from
/// capturing a thumbnail of this screen for the app switcher when the app is
/// backgrounded.
///
/// Wrap anything that renders a bearer secret: the recovery seed, an ecash
/// token. Do not wrap receive addresses or invoices; those are meant to be
/// shared, and users screenshot them deliberately.
class SecureScreen extends StatefulWidget {
  final Widget child;

  const SecureScreen({super.key, required this.child});

  @override
  State<SecureScreen> createState() => _SecureScreenState();
}

class _SecureScreenState extends State<SecureScreen> {
  @override
  void initState() {
    super.initState();
    _activeRequests++;
    if (_activeRequests == 1) {
      _setSecure(true);
    }
  }

  @override
  void dispose() {
    _activeRequests--;
    if (_activeRequests == 0) {
      _setSecure(false);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
