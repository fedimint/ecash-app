import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:ecashapp/deep_link_handler.dart';
import 'package:ecashapp/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:ecashapp/generated/app_localizations.dart';
import 'package:ecashapp/splash.dart';
import 'package:ecashapp/theme.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

/// vector_map_tiles (the map's vector tile renderer) cancels in-flight tile
/// jobs whenever the map moves, which surfaces benign `CancellationException`
/// ("Cancelled") errors. They are harmless but flood the logs, so we drop them.
bool _isTileCancellation(Object error) =>
    error.runtimeType.toString() == 'CancellationException';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Filter out the benign map-tile cancellation noise; forward everything else
  // to the default handlers unchanged.
  final defaultOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    if (_isTileCancellation(details.exception)) return;
    defaultOnError?.call(details);
  };
  WidgetsBinding.instance.platformDispatcher.onError =
      (error, stack) => _isTileCancellation(error);

  // Android only: NWC is the sole user of the foreground task plugin, and it is
  // not offered on iOS because nothing there can keep the listener alive.
  if (Platform.isAndroid) {
    FlutterForegroundTask.initCommunicationPort();
  }

  // Best effort, and deliberately outside the guard below: AppLogger degrades
  // to console-only when this fails, and losing the log must not be the reason
  // the app does not start.
  try {
    await AppLogger.init();
  } catch (e, stack) {
    debugPrint("Logger initialization failed: $e\n$stack");
  }

  // Everything from here to runApp happens before the first frame. An uncaught
  // exception in it leaves the FlutterViewController's own view on screen — a
  // blank white screen, with no crash and therefore no crash report. Draw the
  // failure instead of nothing.
  try {
    // Initialize deep link handler early to catch cold start links
    await DeepLinkHandler().init();

    // On iOS the Rust code is statically linked into the Runner binary, so
    // there's no separate dylib to dlopen — load symbols from the current process.
    if (Platform.isIOS) {
      await RustLib.init(
        externalLibrary: ExternalLibrary.process(iKnowHowToUseIt: true),
      );
    } else {
      await RustLib.init();
    }
    final packageInfo = await PackageInfo.fromPlatform();
    AppLogger.instance.info(
      "Starting ecashapp. Version ${packageInfo.version} Build Number: ${packageInfo.buildNumber}",
    );
    final Directory dir;
    if (Platform.isLinux) {
      final appName = kDebugMode ? 'ecash-app-dev' : 'ecash-app';
      final homeDir = Platform.environment['HOME']!;
      dir = Directory('$homeDir/.local/share/$appName');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
    } else {
      dir = await getApplicationDocumentsDirectory();
    }
    runApp(ecashapp(dir: dir));
  } catch (e, stack) {
    AppLogger.instance.error("Startup failed before runApp: $e\n$stack");
    runApp(StartupFailureApp(error: e, stackTrace: stack));
  }
}

class ecashapp extends StatelessWidget {
  final Directory dir;
  const ecashapp({super.key, required this.dir});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "ecashapp",
      debugShowCheckedModeBanner: false,
      theme: cypherpunkNinjaTheme,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('en'), Locale('es')],
      home: Splash(dir: dir),
    );
  }
}

/// Shown when startup throws before `runApp`. Deliberately dependency-free —
/// no localization, no Rust, no plugins — because anything it touched could be
/// the thing that just failed. The error is selectable so it can be copied out
/// of a TestFlight build, where there is no console.
class StartupFailureApp extends StatelessWidget {
  final Object error;
  final StackTrace stackTrace;

  const StartupFailureApp({
    super.key,
    required this.error,
    required this.stackTrace,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "ecashapp",
      debugShowCheckedModeBanner: false,
      theme: cypherpunkNinjaTheme,
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.error_outline, color: Colors.redAccent),
                const SizedBox(height: 16),
                const Text(
                  "Ecash App failed to start",
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: SingleChildScrollView(
                    child: SelectableText(
                      "$error\n\n$stackTrace",
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
