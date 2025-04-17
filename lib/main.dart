import 'package:carbine/frb_generated.dart';
import 'package:carbine/lib.dart';
import 'package:carbine/multimint.dart';

import 'package:flutter/material.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  Multimint? multimint;

  @override
  void initState() {
    super.initState();
    _initMultimint();
  }

  Future<void> _initMultimint() async {
    try {
      print("Initializing multimint...");
      final instance = await initMultimint();
      print("Initialized multimint!");
      setState(() {
        multimint = instance;
      });
    } catch (e) {
      print('Failed to initialize Multimint: $e');
    }
  }

  void _onJoinFederationPressed() {
    print("Join Federation button pressed");
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Multimint App')),
        body: Center(
          child: multimint == null
              ? const CircularProgressIndicator()
              : ElevatedButton(
                  onPressed: _onJoinFederationPressed,
                  child: const Text('Join Federation'),
                ),
        ),
      ),
    );
  }
}
