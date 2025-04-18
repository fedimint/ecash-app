
import 'package:carbine/lib.dart';
import 'package:flutter/material.dart';

class FederationSidebar extends StatelessWidget {
  final Future<List<FederationSelector>> federationsFuture;
  final void Function(FederationSelector) onFederationSelected;

  const FederationSidebar({
    super.key,
    required this.federationsFuture,
    required this.onFederationSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: FutureBuilder<List<FederationSelector>>(
        future: federationsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          } else if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          } else if (!snapshot.hasData || snapshot.data!.isEmpty) {
            return const Center(child: Text('No federations found'));
          }

          final federations = snapshot.data;
          return ListView(
            padding: EdgeInsets.zero,
            children: [
              const DrawerHeader(
                decoration: BoxDecoration(color: Colors.blue),
                child: Text('Federations', style: TextStyle(color: Colors.white)),
              ),
              ...federations!.map((selector) => ListTile(
                title: Text(selector.federationName),
                onTap: () {
                  Navigator.of(context).pop();
                  onFederationSelected(selector);
                  print('Selected federation: $selector');
                },
              )),
            ],
          );
        },
      )
    );
  }
}