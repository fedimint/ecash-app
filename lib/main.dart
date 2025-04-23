import 'package:carbine/dashboard.dart';
import 'package:carbine/discover.dart';
import 'package:carbine/frb_generated.dart';
import 'package:carbine/join.dart';
import 'package:carbine/lib.dart';
import 'package:carbine/sidebar.dart';
import 'package:flutter/material.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(const MyApp());
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
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();

    federations().then((feds) {
      if (feds.isNotEmpty) {
        setState(() {
          _selectedFederation = feds.first;
        });
      }
    });

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

  void _onScanPressed(BuildContext context) async {
    final result = await Navigator.push<FederationSelector>(
      context,
      MaterialPageRoute(builder: (context) => const JoinFederationPage()),
    );

    if (result != null) {
      _setSelectedFederation(result);
      _refreshFederations();
    }
  }

  void _onNavBarTapped(int index, BuildContext context) async {
    setState(() {
      _currentIndex = index;
      _selectedFederation = null;
    });

    if (index == 1) {
      _onScanPressed(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Builder(
        builder: (innerContext) => Scaffold(
          appBar: AppBar(title: const Text('Multimint App')),
          drawer: FederationSidebar(
            key: ValueKey(_refreshTrigger),
            federationsFuture: _federationFuture,
            onFederationSelected: _setSelectedFederation,
          ),
          body: _selectedFederation == null
                ? const Discover()
                : Dashboard(fed: _selectedFederation!),
          bottomNavigationBar: BottomNavigationBar(
            currentIndex: _currentIndex,
            onTap: (index) => _onNavBarTapped(index, innerContext),
            items: const [
              BottomNavigationBarItem(
                icon: Icon(Icons.explore),
                label: 'Discover',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.qr_code_scanner),
                label: 'Scan',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

