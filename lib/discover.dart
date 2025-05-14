import 'package:carbine/fed_preview.dart';
import 'package:carbine/lib.dart';
import 'package:carbine/theme.dart';
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
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Discover Federations', style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        elevation: 0,
      ),
      body: FutureBuilder<List<PublicFederation>>(
        future: _futureFeds,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          } else if (snapshot.hasError) {
            return Center(child: Text("Error: ${snapshot.error}", style: TextStyle(color: theme.colorScheme.error)));
          } else if (!snapshot.hasData || snapshot.data!.isEmpty) {
            return const Center(child: Text("No public federations available to join"));
          }

          final federations = snapshot.data!;
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemCount: federations.length,
            itemBuilder: (context, index) {
              final federation = federations[index];
              return Card(
                elevation: 2,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: federation.picture != null && federation.picture!.isNotEmpty
                            ? Image.network(
                                federation.picture!,
                                width: 50,
                                height: 50,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) =>
                                    Image.asset('assets/images/fedimint.png', width: 50, height: 50),
                              )
                            : Image.asset('assets/images/fedimint.png', width: 50, height: 50),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              federation.federationName,
                              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              "Network: ${federation.network}",
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            if (federation.about != null && federation.about!.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Text(
                                federation.about!,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          minimumSize: const Size(70, 36),
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                        ),
                        onPressed: () async {
                          setState(() => _gettingMetadata = federation);
                          final meta = await getFederationMeta(inviteCode: federation.inviteCodes.first);
                          setState(() => _gettingMetadata = null);
                          final fed = await showCarbineModalBottomSheet(
                            context: context,
                            child: FederationPreview(
                                federationName: meta.$2.federationName,
                                inviteCode: meta.$2.inviteCode,
                                welcomeMessage: meta.$1.welcome,
                                imageUrl: meta.$1.picture,
                                joinable: true,
                                guardians: meta.$1.guardians,
                                network: meta.$2.network,
                              ),
                          );

                          await Future.delayed(const Duration(milliseconds: 400));
                          widget.onJoin(fed);
                          if (context.mounted) Navigator.pop(context);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text("Joined ${fed.federationName}")),
                          );
                        },
                        child: (_gettingMetadata != null && _gettingMetadata == federation)
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : const Text("Join"),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
