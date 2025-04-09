import 'dart:ffi';

import 'package:flutter/material.dart';

final dylib = DynamicLibrary.open("target-nix/release/libcarbine_fedimint.so");

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
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
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool hasJoinedMint = false; // Toggle this to false to test the join screen
  bool isDrawerOpen = false;

  List<String> joinedFederations = ['Fedimint Alpha', 'Fedimint Beta'];
  int balanceInSats = 42000;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: hasJoinedMint ? buildMainScreen() : buildJoinScreen(),
    );
  }

  Widget buildJoinScreen() {
    return Center(
      child: ElevatedButton(
        onPressed: () {
          setState(() {
            hasJoinedMint = true;
          });
        },
        child: Text('Join Federation'),
      ),
    );
  }

  Widget buildMainScreen() {
    return Row(
      children: [
        // Navigation Drawer (collapsible)
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
        // Main content area
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

