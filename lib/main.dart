import 'package:carbine/dashboard.dart';
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
  FederationSelector? _selectedFederation;

  @override
  void initState() {
    super.initState();
    _refreshFederations();
  }

  void _setSelectedFederation(FederationSelector fed) {
    setState(() {
      _selectedFederation = fed;
    });
  }

  void _refreshFederations() {
    setState(() {
      _federationFuture = federations();
      _refreshTrigger++;
    });
  }

  void _onJoinFederationPressed(BuildContext context) async {
    final result = await Navigator.push<FederationSelector>(
      context,
      MaterialPageRoute(builder: (context) => const JoinFederationPage())
    );

    if (result != null) {
      _setSelectedFederation(result);
      _refreshFederations();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Multimint App')),
        drawer: FederationSidebar(
          key: ValueKey(_refreshTrigger),
          federationsFuture: _federationFuture,
          onFederationSelected: _setSelectedFederation,
        ),
        body: _selectedFederation == null
          ? Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () => _onJoinFederationPressed(context),
                  child: const Text('Join Federation'),
                ),
              ),
            )
          : Dashboard(
              fed: _selectedFederation!,
            ),
      ),
    );
  }
}
