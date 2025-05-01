import 'package:carbine/dashboard.dart';
import 'package:carbine/discover.dart';
import 'package:carbine/frb_generated.dart';
import 'package:carbine/scan.dart';
import 'package:carbine/lib.dart';
import 'package:carbine/sidebar.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(const MyApp());
}

int threshold(int totalPeers) {
  final maxEvil = (totalPeers - 1) ~/ 3;
  return totalPeers - maxEvil;
}

String formatBalance(BigInt? msats, bool showMsats) {
  if (msats == null) return showMsats ? '0 msats' : '0 sats';

  if (showMsats) {
    final formatter = NumberFormat('#,##0', 'en_US');
    var formatted = formatter.format(msats.toInt());
    formatted = formatted.replaceAll(',', ' ');
    return '$formatted msats';
  } else {
    final sats = msats ~/ BigInt.from(1000);
    final formatter = NumberFormat('#,##0', 'en_US');
    var formatted = formatter.format(sats.toInt());
    return '$formatted sats';
  }
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

  void _onJoinPressed(FederationSelector fed) {
    _setSelectedFederation(fed);
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
      MaterialPageRoute(builder: (context) => const ScanQRPage()),
    );

    if (result != null) {
      _setSelectedFederation(result);
      _refreshFederations();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Joined ${result.federationName}")),
      );
    } else {
      print('Result is null, not updating federations');
    }
  }

  void _onNavBarTapped(int index, BuildContext context) async {
    setState(() {
      _currentIndex = index;
      if (index == 0) {
        _selectedFederation = null;
      }
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
          appBar: AppBar(),
          drawer: FederationSidebar(
            key: ValueKey(_refreshTrigger),
            federationsFuture: _federationFuture,
            onFederationSelected: _setSelectedFederation,
          ),
          body: _selectedFederation == null
                ? Discover(onJoin: _onJoinPressed)
                : Dashboard(key: ValueKey(_selectedFederation!.federationId), fed: _selectedFederation!),
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

