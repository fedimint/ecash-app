import 'dart:io';

import 'package:ecashapp/generated/frb_generated.dart';
import 'package:ecashapp/splash.dart';
import 'package:ecashapp/theme.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppLogger.init();
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
