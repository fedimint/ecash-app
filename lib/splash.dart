import 'dart:io';

import 'package:ecashapp/app.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';
import 'create_wallet.dart';

class Splash extends StatefulWidget {
  final Directory dir;
  const Splash({super.key, required this.dir});

  @override
  State<Splash> createState() => _SplashState();
}

class _SplashState extends State<Splash> {
  @override
  void initState() {
    super.initState();
    _checkWalletStatus();
  }

  Future<void> _checkWalletStatus() async {
    final walletDir = Directory('${widget.dir.path}/client.db');
    final exists = await walletDir.exists();
    AppLogger.instance.info("Wallet exists: $exists");

    if (!mounted) return;
    final Widget screen;
    if (exists) {
      await loadMultimint(path: widget.dir.path);
      final initialFeds = await federations();
      screen = MyApp(
        initialFederations: initialFeds,
        recoverFederationInviteCodes: false,
      );
    } else {
      screen = CreateWallet(dir: widget.dir);
    }

    Navigator.of(
      context,
    ).pushReplacement(MaterialPageRoute(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Image(
          image: AssetImage('assets/images/e-cash-app.png'),
          width: 200,
        ),
      ),
    );
  }
}
