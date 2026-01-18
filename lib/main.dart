import 'dart:io';

import 'package:ecashapp/deep_link_handler.dart';
import 'package:ecashapp/frb_generated.dart';
import 'package:ecashapp/splash.dart';
import 'package:ecashapp/theme.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize foreground task
  FlutterForegroundTask.initCommunicationPort();

  await AppLogger.init();

  // Initialize deep link handler early to catch cold start links
  await DeepLinkHandler().init();

  await RustLib.init();
  final packageInfo = await PackageInfo.fromPlatform();
  AppLogger.instance.info(
    "Starting ecashapp. Version ${packageInfo.version} Build Number: ${packageInfo.buildNumber}",
  );
  final dir = await getApplicationDocumentsDirectory();
  runApp(ecashapp(dir: dir));
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
      home: Splash(dir: dir),
    );
  }
}
