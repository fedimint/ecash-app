import 'frb_generated.dart';
import 'package:flutter/material.dart';

void main() async {
  await RustLib.init();
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Federation App',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool hasJoinedMint = false;
  bool isDrawerOpen = false;

  List<String> joinedFederations = ['Fedimint Alpha', 'Fedimint Beta'];
  int balanceInSats = 42000;

  // New state for input handling
  bool showTextField = false;
  final TextEditingController _controller = TextEditingController();

  Future<void> _joinFederation(String code) async {
    print("Joining federation...");
    try {
      await RustLib.instance.api.crateJoinFederation(inviteCode: code);
      setState(() {
        hasJoinedMint = true;
      });
      print("Successfully joined federation");
    } catch (e) {
      print("Failed to join federation: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: hasJoinedMint ? buildMainScreen() : buildJoinScreen(),
    );
  }

  Widget buildJoinScreen() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (showTextField) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32.0),
              child: TextField(
                controller: _controller,
                decoration: InputDecoration(
                  labelText: 'Enter Federation Code',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            SizedBox(height: 20),
            ElevatedButton(
              onPressed: () {
                final code = _controller.text.trim();
                print(code);
                if (code.isNotEmpty) {
                  _joinFederation(code);
                }
              },
              child: Text('Submit Code'),
            ),
          ] else
            ElevatedButton(
              onPressed: () {
                setState(() {
                  showTextField = true;
                });
              },
              child: Text('Join Federation'),
            ),
        ],
      ),
    );
  }

  Widget buildMainScreen() {
    return Row(
      children: [
        AnimatedContainer(
          duration: Duration(milliseconds: 300),
          width: isDrawerOpen ? 200 : 60,
          color: Colors.grey.shade200,
          child: Column(
            children: [
              IconButton(
                icon: Icon(isDrawerOpen ? Icons.arrow_back_ios : Icons.menu),
                onPressed: () {
                  setState(() {
                    isDrawerOpen = !isDrawerOpen;
                  });
                },
              ),
              if (isDrawerOpen)
                ...joinedFederations.map((fed) => ListTile(
                      title: Text(fed),
                      onTap: () {},
                    )),
            ],
          ),
        ),
        Expanded(
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '$balanceInSats sats',
                  style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ElevatedButton(
                      onPressed: () {
                        // handle receive
                      },
                      child: Text('Receive'),
                    ),
                    SizedBox(width: 20),
                    ElevatedButton(
                      onPressed: () {
                        // handle send
                      },
                      child: Text('Send'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}


