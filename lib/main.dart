import 'dart:io';

import 'package:carbine/frb_generated.dart';
import 'package:carbine/splash.dart';
import 'package:carbine/theme.dart';
import 'package:carbine/utils.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppLogger.init();
  await RustLib.init();
  AppLogger.instance.info("Starting Carbine...");
  final dir = await getApplicationDocumentsDirectory();
  runApp(Carbine(dir: dir));
}

class Carbine extends StatelessWidget {
  final Directory dir;
  const Carbine({super.key, required this.dir});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "Carbine",
      debugShowCheckedModeBanner: false,
      theme: cypherpunkNinjaTheme,
      home: Splash(dir: dir),
    );
  }
}
