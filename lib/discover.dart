import 'package:carbine/fed_preview.dart';
import 'package:carbine/lib.dart';
import 'package:flutter/material.dart';

class Discover extends StatefulWidget {
  final void Function(FederationSelector fed) onJoin;
  const Discover({super.key, required this.onJoin});

  @override
  State<Discover> createState() => _Discover();
}

class _Discover extends State<Discover> {
  late Future<List<PublicFederation>> _futureFeds;
  PublicFederation? _gettingMetadata;

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
          return const Center(child: Text("No public federations available to join"));
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
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("Network: ${federation.network}"),
                  if (federation.about != null && federation.about!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4.0),
                      child: Text(
                        federation.about!,
                        style: TextStyle(color: Colors.grey[700], fontSize: 12),
                      ),
                    ),
                ],
              ),
              trailing: ElevatedButton(
                onPressed: () async {
                  setState(() {
                    _gettingMetadata = federation;
                  });
                  final meta = await getFederationMeta(inviteCode: federation.inviteCodes.first);
                  final fed = await showModalBottomSheet(
                    context: context,
                    isScrollControlled: true,
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                    ),
                    builder: (_) => Padding(
                      padding: EdgeInsets.only(
                        bottom: MediaQuery.of(context).viewInsets.bottom,
                      ),
                      child: Container(
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                        ),
                        child: FederationPreview(
                          federationName: meta.$2.federationName,
                          inviteCode: meta.$2.inviteCode,
                          welcomeMessage: meta.$1.welcome,
                          imageUrl: meta.$1.picture,
                          joinable: true,
                          guardians: meta.$1.guardians,
                        ),
                      ),
                    ),
                  );

                  setState(() {
                    _gettingMetadata = null;
                  });
                  await Future.delayed(const Duration(milliseconds: 400));
                  widget.onJoin(fed);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text("Joined ${fed.federationName}")),
                  );
                },
                child: (_gettingMetadata != null && _gettingMetadata! == federation) ? const CircularProgressIndicator(color: Colors.white) : const Text("Join"),
              ),
            );
          },
        );
      },
    );
  }
}
