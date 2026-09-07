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

  // Best effort and outside the guard below: AppLogger degrades to console-only
  // when this fails, and losing the log must not stop the app starting.
  try {
    await AppLogger.init();
  } catch (e, stack) {
    debugPrint("Logger initialization failed: $e\n$stack");
  }

  // Everything up to runApp runs before the first frame, so an uncaught
  // exception there leaves the FlutterViewController's white view on screen
  // with no crash report. Draw the failure instead.
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
    // Render before logging: AppLogger._log writes synchronously and unguarded,
    // so an unwritable log file would throw here and leave exactly the blank
    // screen this fallback exists to replace.
    runApp(StartupFailureApp(error: e, stackTrace: stack));
    try {
      AppLogger.instance.error("Startup failed before runApp: $e\n$stack");
    } catch (_) {
      debugPrint("Startup failed before runApp: $e\n$stack");
    }
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

/// Shown when startup throws before `runApp`. Dependency-free — no
/// localization, Rust or plugins — since anything it touched could be what just
/// failed. Selectable so the error can be copied out of a TestFlight build.
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
                // Intentionally English-only: this screen must not depend on
                // localization, which may be part of what failed.
                const Text(
                  "Ecash App failed to start", // i18n-ignore
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
