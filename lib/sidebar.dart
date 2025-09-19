import 'package:ecashapp/fed_preview.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/theme.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';

class FederationSidebar extends StatefulWidget {
  final List<(FederationSelector, bool)> initialFederations;
  final void Function(FederationSelector, bool) onFederationSelected;
  final VoidCallback onLeaveFederation;

  const FederationSidebar({
    super.key,
    required this.initialFederations,
    required this.onFederationSelected,
    required this.onLeaveFederation,
  });

  @override
  State<FederationSidebar> createState() => FederationSidebarState();
}

class FederationSidebarState extends State<FederationSidebar> {
  late List<(FederationSelector, bool)> _feds;
  int _refreshTrigger = 0;

  @override
  void initState() {
    super.initState();
    _feds = widget.initialFederations;
    _refreshFederations();
  }

  void _refreshFederations() async {
    final feds = await federations();
    setState(() {
      _feds = feds;
      _refreshTrigger++;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.6), blurRadius: 12),
          ],
        ),
        child:
            _feds.isEmpty
                ? const Center(child: Text('No federations found'))
                : ListView(
                  padding: EdgeInsets.zero,
                  key: ValueKey(_refreshTrigger),
                  children: [
                    Container(
                      height: 80,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.grey[900],
                        border: Border(
                          bottom: BorderSide(color: Colors.grey.shade800),
                        ),
                      ),
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Federations',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    ..._feds.map(
                      (selector) => FederationListItem(
                        fed: selector.$1,
                        isRecovering: selector.$2,
                        onTap: () {
                          Navigator.of(context).pop();
                          widget.onFederationSelected(selector.$1, selector.$2);
                        },
                        onLeaveFederation: widget.onLeaveFederation,
                      ),
                    ),
                  ],
                ),
      ),
    );
  }
}

class FederationListItem extends StatefulWidget {
  final FederationSelector fed;
  final bool isRecovering;
  final VoidCallback onTap;
  final VoidCallback onLeaveFederation;

  const FederationListItem({
    super.key,
    required this.fed,
    required this.onTap,
    required this.isRecovering,
    required this.onLeaveFederation,
  });

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
    await _loadBalance();
    await _loadFederationMeta();
    if (!mounted) return;
    setState(() {
      isLoading = false;
    });
  }

  Future<void> _loadFederationMeta() async {
    try {
      final meta = await getFederationMeta(
        federationId: widget.fed.federationId,
      );
      if (!mounted) return;
      setState(() {
        if (meta.picture?.isNotEmpty ?? false) {
          federationImageUrl = meta.picture;
        }
        if (meta.welcome?.isNotEmpty ?? false) {
          welcomeMessage = meta.welcome;
        }
        guardians = meta.guardians;
      });
    } catch (e) {
      AppLogger.instance.error('Failed to load federation metadata: $e');
    }
  }

  Future<void> _loadBalance() async {
    if (!widget.isRecovering) {
      final bal = await balance(federationId: widget.fed.federationId);
      if (!mounted) return;
      setState(() {
        balanceMsats = bal;
        isLoading = false;
      });
    } else {
      AppLogger.instance.warn(
        "FederationListItemState: we are still recovering, not getting balance",
      );
    }
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
    final onlineColor =
        numOnlineGuardians == numGuardians
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
                  backgroundImage:
                      federationImageUrl != null
                          ? NetworkImage(federationImageUrl!)
                          : const AssetImage('assets/images/fedimint.png')
                              as ImageProvider,
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
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        widget.isRecovering
                            ? "Recovering..."
                            : isLoading
                            ? 'Loading...'
                            : formatBalance(balanceMsats, false),
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 4),
                      guardians == null
                          ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              color: Theme.of(context).colorScheme.primary,
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
                  icon: const Icon(Icons.groups_outlined),
                  color: Theme.of(context).colorScheme.primary,
                  onPressed: () {
                    showAppModalBottomSheet(
                      context: context,
                      childBuilder: () async {
                        return FederationPreview(
                          fed: widget.fed,
                          welcomeMessage: welcomeMessage,
                          imageUrl: federationImageUrl,
                          joinable: false,
                          guardians: guardians,
                          onLeaveFederation: widget.onLeaveFederation,
                        );
                      },
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
