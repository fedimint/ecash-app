import 'package:carbine/frb_generated.dart';
import 'package:carbine/join.dart';
import 'package:carbine/lib.dart';
import 'package:carbine/sidebar.dart';

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
  late Future<List<FederationSelector>> _federationFuture;
  int _refreshTrigger = 0;

  @override
  void initState() {
    super.initState();
    _refreshFederations();
  }

  void _refreshFederations() {
    setState(() {
      _federationFuture = federations();
      _refreshTrigger++;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Multimint App')),
        drawer: FederationSidebar(
          key: ValueKey(_refreshTrigger),
          federationsFuture: _federationFuture,
        ),
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => JoinFederationPage(onFederationJoined: _refreshFederations,)),
                );
              },
              child: const Text('Join Federation'),
            ),
          ),
        ),
      ),
    );
  }
}
