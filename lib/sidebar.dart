import 'package:carbine/fed_preview.dart';
import 'package:carbine/lib.dart';
import 'package:carbine/main.dart';
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
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.6),
              blurRadius: 12,
            ),
          ],
        ),
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
                  height: 80,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.grey[900], // Slightly lighter for header contrast
                    border: Border(
                      bottom: BorderSide(color: Colors.grey.shade800),
                    ),
                  ),
                  alignment: Alignment.centerLeft,
                  child: const Text(
                    'Federations',
                    style: TextStyle(
                      color: Colors.greenAccent,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                ...federations!.map((selector) => FederationListItem(
                  fed: selector,
                  onTap: () {
                    Navigator.of(context).pop();
                    onFederationSelected(selector);
                  },
                )),
              ],
            );
          },
        ),
      ),
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
  List<Guardian>? guardians;

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
      final meta = await getFederationMeta(inviteCode: widget.fed.inviteCode);
      setState(() {
        if (meta.$1.picture?.isNotEmpty ?? false) {
          federationImageUrl = meta.$1.picture;
        }
        if (meta.$1.welcome?.isNotEmpty ?? false) {
          welcomeMessage = meta.$1.welcome;
        }
        guardians = meta.$1.guardians;
      });
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

  bool get allGuardiansOnline =>
      guardians != null &&
      guardians!.isNotEmpty &&
      guardians!.every((g) => g.version != null);

  int get numOnlineGuardians =>
    guardians != null ? guardians!.where((g) => g.version != null).length : 0;

  @override
  Widget build(BuildContext context) {
    final numGuardians = guardians?.length ?? 0;
    final thresh = guardians != null ? threshold(numGuardians) : 0;
    final onlineColor = numOnlineGuardians == numGuardians
        ? Colors.greenAccent
        : numOnlineGuardians >= thresh
            ? Colors.amberAccent
            : Colors.redAccent;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 6),
      child: Material(
        color: Colors.grey[900],
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: widget.onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 24,
                  backgroundImage: federationImageUrl != null
                      ? NetworkImage(federationImageUrl!)
                      : const AssetImage('assets/images/fedimint.png') as ImageProvider,
                  backgroundColor: Colors.black,
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
                        style: Theme.of(context).textTheme.bodyLarge!.copyWith(
                              fontWeight: FontWeight.bold,
                              color: Colors.greenAccent,
                            ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        isLoading
                            ? 'Loading...'
                            : formatBalance(balanceMsats, false),
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 4),
                      guardians == null
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                color: Colors.greenAccent,
                                strokeWidth: 2,
                              ),
                            )
                          : Row(
                              children: [
                                Text(
                                  guardians!.isEmpty
                                      ? 'Offline'
                                      : numGuardians == 1
                                          ? '1 guardian'
                                          : '$numGuardians guardians',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                                const SizedBox(width: 6),
                                Icon(Icons.circle, size: 10, color: onlineColor),
                              ],
                            ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.qr_code),
                  color: Colors.greenAccent,
                  onPressed: () {
                    showModalBottomSheet(
                      context: context,
                      backgroundColor:
                          Theme.of(context).bottomSheetTheme.backgroundColor,
                      isScrollControlled: true,
                      shape: const RoundedRectangleBorder(
                        borderRadius:
                            BorderRadius.vertical(top: Radius.circular(24)),
                      ),
                      builder: (_) => Padding(
                        padding: EdgeInsets.only(
                          bottom: MediaQuery.of(context).viewInsets.bottom,
                        ),
                        child: FederationPreview(
                          federationName: widget.fed.federationName,
                          inviteCode: widget.fed.inviteCode,
                          welcomeMessage: welcomeMessage,
                          imageUrl: federationImageUrl,
                          joinable: false,
                          guardians: guardians,
                          network: widget.fed.network,
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
