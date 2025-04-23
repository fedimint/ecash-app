import 'package:carbine/lib.dart';
import 'package:flutter/material.dart';

class Discover extends StatefulWidget {
  const Discover({super.key});

  @override
  State<Discover> createState() => _Discover();
}

class _Discover extends State<Discover> {
  late Future<List<PublicFederation>> _futureFeds;

  @override
  void initState() {
    super.initState();
    _futureFeds = listFederationsFromNostr(forceUpdate: false);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<PublicFederation>>(
      future: _futureFeds,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        } else if (snapshot.hasError) {
          return Center(child: Text("Error: ${snapshot.error}"));
        } else if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return const Center(child: Text("No federations found."));
        }

        final federations = snapshot.data!;
        return ListView.builder(
          itemCount: federations.length,
          itemBuilder: (context, index) {
            final federation = federations[index];
            return ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              leading: CircleAvatar(
                backgroundColor: Colors.transparent,
                child: ClipOval(
                  child: federation.picture != null && federation.picture!.isNotEmpty
                      ? Image.network(
                          federation.picture!,
                          width: 40,
                          height: 40,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) {
                            return Image.asset(
                              'assets/images/fedimint.png',
                              width: 40,
                              height: 40,
                              fit: BoxFit.cover,
                            );
                          },
                        )
                      : Image.asset(
                          'assets/images/fedimint.png',
                          width: 40,
                          height: 40,
                          fit: BoxFit.cover,
                        ),
                ),
              ),
              title: Text(federation.federationName),
              subtitle: Text("Network: ${federation.network}"),
              trailing: ElevatedButton(
                onPressed: () {
                  // Handle join logic
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text("Joining ${federation.federationName}...")),
                  );
                },
                child: const Text("Join"),
              ),
            );
          },
        );
      },
    );
  }
}