
import 'package:carbine/fed_preview.dart';
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
              Container(
                height: 80, // Make this as short as you like
                padding: const EdgeInsets.all(16),
                decoration: const BoxDecoration(color: Colors.black87),
                alignment: Alignment.centerLeft,
                child: const Text(
                  'Federations',
                  style: TextStyle(color: Colors.white, fontSize: 18),
                ),
              ),
              ...federations!.map((selector) => FederationListItem(
                fed: selector,
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

class FederationListItem extends StatefulWidget {
  final FederationSelector fed;
  final VoidCallback onTap;

  const FederationListItem({super.key, required this.fed, required this.onTap});

  @override
  State<FederationListItem> createState() => _FederationListItemState();
}

class _FederationListItemState extends State<FederationListItem> {
  BigInt? balanceMsats;
  bool isLoading = true;
  String? federationImageUrl;
  String? welcomeMessage;

  @override
  void initState() {
    super.initState();
    _initializeData();
  }

  Future<void> _initializeData() async {
    await Future.wait([
      _loadBalance(),
      _loadFederationMeta(),
    ]);
    setState(() {
      isLoading = false;
    });
  }

  Future<void> _loadFederationMeta() async {
    try {
        final meta = await getFederationMeta(federationId: widget.fed.federationId);
        if (meta.picture != null && meta.picture!.isNotEmpty) {
          setState(() {
            federationImageUrl = meta.picture;
          });
        }
        if (meta.welcome != null && meta.welcome!.isNotEmpty) {
          setState(() {
            welcomeMessage = meta.welcome;
          });
        }
    } catch (e) {
      print('Failed to load federation metadata: $e');
    }
  }

  Future<void> _loadBalance() async {
    final bal = await balance(federationId: widget.fed.federationId);
    setState(() {
      balanceMsats = bal;
      isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final numGuardians = widget.fed.numPeers;
    return InkWell(
      onTap: widget.onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            CircleAvatar(
              radius: 24,
              backgroundImage: federationImageUrl != null
                  ? NetworkImage(federationImageUrl!)
                  : const AssetImage('assets/images/fedimint.png') as ImageProvider,
              onBackgroundImageError: (_, __) {
                setState(() {
                  federationImageUrl = null;
                });
              },
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.fed.federationName,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    isLoading
                        ? 'Loading...'
                        : '${balanceMsats ?? 'Unavailable'} msats',
                  ),
                  Text(numGuardians == BigInt.one ? '1 guardian' : '$numGuardians guardians'),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.qr_code),
              onPressed: () {
                showModalBottomSheet(
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
                        federationName: widget.fed.federationName,
                        inviteCode: widget.fed.inviteCode,
                        welcomeMessage: welcomeMessage,
                        imageUrl: federationImageUrl,
                        joinable: false,
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}