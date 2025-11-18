import 'package:ecashapp/db.dart';
import 'package:ecashapp/fed_preview.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/providers/preferences_provider.dart';
import 'package:ecashapp/theme.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class FederationPreviewData {
  BigInt? balanceMsats;
  bool isLoading;
  String? federationImageUrl;
  String? welcomeMessage;
  List<Guardian>? guardians;

  FederationPreviewData({
    this.balanceMsats,
    this.isLoading = true,
    this.federationImageUrl,
    this.welcomeMessage,
    this.guardians,
  });
}

class FederationSidebar extends StatefulWidget {
  final List<(FederationSelector, bool)> initialFederations;
  final void Function(FederationSelector, bool) onFederationSelected;
  final VoidCallback onLeaveFederation;
  final VoidCallback onSettingsPressed;

  const FederationSidebar({
    super.key,
    required this.initialFederations,
    required this.onFederationSelected,
    required this.onLeaveFederation,
    required this.onSettingsPressed,
  });

  @override
  State<FederationSidebar> createState() => FederationSidebarState();
}

class FederationSidebarState extends State<FederationSidebar> {
  late List<(FederationSelector, bool, FederationPreviewData)> _feds;

  @override
  void initState() {
    super.initState();
    // Initialize with loading state for each federation
    _feds =
        widget.initialFederations
            .map((fed) => (fed.$1, fed.$2, FederationPreviewData()))
            .toList();
    _refreshFederations();
  }

  Future<FederationPreviewData> getFederationPreviewData(
    FederationSelector fed,
    bool isRecovering,
  ) async {
    final data = FederationPreviewData();

    // Load balance
    if (!isRecovering) {
      try {
        final bal = await balance(federationId: fed.federationId);
        data.balanceMsats = bal;
      } catch (e) {
        AppLogger.instance.error('Failed to load balance: $e');
      }
    } else {
      AppLogger.instance.warn(
        "getFederationData: we are still recovering, not getting balance",
      );
    }

    // Load federation metadata
    try {
      final meta = await getFederationMeta(federationId: fed.federationId);
      if (meta.picture?.isNotEmpty ?? false) {
        data.federationImageUrl = meta.picture;
      }
      if (meta.welcome?.isNotEmpty ?? false) {
        data.welcomeMessage = meta.welcome;
      }
      data.guardians = meta.guardians;
    } catch (e) {
      AppLogger.instance.error('Failed to load federation metadata: $e');
    }

    data.isLoading = false;
    return data;
  }

  void _refreshFederations() async {
    final feds = await federations();
    final fedsWithData = <(FederationSelector, bool, FederationPreviewData)>[];

    for (final fed in feds) {
      final data = await getFederationPreviewData(fed.$1, fed.$2);
      fedsWithData.add((fed.$1, fed.$2, data));
    }

    setState(() {
      _feds = fedsWithData;
    });
  }

  Future<void> _onReorder(int oldIndex, int newIndex) async {
    setState(() {
      if (newIndex > oldIndex) {
        newIndex -= 1;
      }
      final item = _feds.removeAt(oldIndex);
      _feds.insert(newIndex, item);
    });

    // Save the new order to the database
    try {
      final order = _feds.map((fed) => fed.$1.federationId).toList();
      await setFederationOrder(order: order);
    } catch (e) {
      AppLogger.instance.error('Failed to save federation order: $e');
    }
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
        child: Column(
          children: [
            Expanded(
              child:
                  _feds.isEmpty
                      ? const Center(child: Text('No federations found'))
                      : Column(
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
                          Expanded(
                            child: ReorderableListView(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 12,
                              ),
                              buildDefaultDragHandles: false,
                              onReorder: _onReorder,
                              children:
                                  _feds
                                      .asMap()
                                      .entries
                                      .map(
                                        (selector) =>
                                            ReorderableDragStartListener(
                                              key: ValueKey(selector.key),
                                              index: selector.key,
                                              child: FederationListItem(
                                                key: ValueKey(
                                                  selector
                                                      .value
                                                      .$1
                                                      .federationId,
                                                ),
                                                fed: selector.value.$1,
                                                isRecovering: selector.value.$2,
                                                data: selector.value.$3,
                                                onTap: () {
                                                  Navigator.of(context).pop();
                                                  widget.onFederationSelected(
                                                    selector.value.$1,
                                                    selector.value.$2,
                                                  );
                                                },
                                                onLeaveFederation:
                                                    widget.onLeaveFederation,
                                              ),
                                            ),
                                      )
                                      .toList(),
                            ),
                          ),
                        ],
                      ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 12.0,
                vertical: 12,
              ),
              child: Material(
                color: Colors.grey[900],
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () {
                    Navigator.of(context).pop();
                    widget.onSettingsPressed();
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 16,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.settings,
                          color: Theme.of(context).colorScheme.primary,
                          size: 24,
                        ),
                        const SizedBox(width: 16),
                        Text(
                          'Settings',
                          style: Theme.of(
                            context,
                          ).textTheme.bodyLarge!.copyWith(
                            fontWeight: FontWeight.bold,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class FederationListItem extends StatelessWidget {
  final FederationSelector fed;
  final bool isRecovering;
  final FederationPreviewData data;
  final VoidCallback onTap;
  final VoidCallback onLeaveFederation;

  const FederationListItem({
    super.key,
    required this.fed,
    required this.isRecovering,
    required this.data,
    required this.onTap,
    required this.onLeaveFederation,
  });

  bool get allGuardiansOnline =>
      data.guardians != null &&
      data.guardians!.isNotEmpty &&
      data.guardians!.every((g) => g.version != null);

  int get numOnlineGuardians =>
      data.guardians != null
          ? data.guardians!.where((g) => g.version != null).length
          : 0;

  @override
  Widget build(BuildContext context) {
    final numGuardians = data.guardians?.length ?? 0;
    final thresh = data.guardians != null ? threshold(numGuardians) : 0;
    final onlineColor =
        numOnlineGuardians == numGuardians
            ? Colors.greenAccent
            : numOnlineGuardians >= thresh
            ? Colors.amberAccent
            : Colors.redAccent;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: Colors.grey[900],
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 24,
                  backgroundImage:
                      data.federationImageUrl != null
                          ? NetworkImage(data.federationImageUrl!)
                          : const AssetImage('assets/images/fedimint.png')
                              as ImageProvider,
                  backgroundColor: Colors.black,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        fed.federationName,
                        style: Theme.of(context).textTheme.bodyLarge!.copyWith(
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        isRecovering
                            ? "Recovering..."
                            : data.isLoading
                            ? 'Loading...'
                            : formatBalance(
                              data.balanceMsats,
                              false,
                              context
                                  .select<PreferencesProvider, BitcoinDisplay>(
                                    (prefs) => prefs.bitcoinDisplay,
                                  ),
                            ),
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 4),
                      data.guardians == null
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
                                data.guardians!.isEmpty
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
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.groups_outlined),
                  color: Theme.of(context).colorScheme.primary,
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    showAppModalBottomSheet(
                      context: context,
                      childBuilder: () async {
                        return FederationPreview(
                          fed: fed,
                          welcomeMessage: data.welcomeMessage,
                          imageUrl: data.federationImageUrl,
                          joinable: false,
                          guardians: data.guardians,
                          onLeaveFederation: onLeaveFederation,
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
