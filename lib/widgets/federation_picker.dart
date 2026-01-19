import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/providers/preferences_provider.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class FederationPickerItem {
  final FederationSelector selector;
  final bool isRecovering;
  final BigInt? balanceMsats;

  FederationPickerItem({
    required this.selector,
    required this.isRecovering,
    this.balanceMsats,
  });
}

Future<(FederationSelector, bool)?> showFederationPicker({
  required BuildContext context,
  required List<(FederationSelector, bool)> federations,
  String? title,
}) async {
  if (federations.isEmpty) {
    return null;
  }

  // If only one federation, return it directly
  if (federations.length == 1) {
    return federations.first;
  }

  return showModalBottomSheet<(FederationSelector, bool)>(
    context: context,
    backgroundColor: Theme.of(context).bottomSheetTheme.backgroundColor,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (context) {
      return SafeArea(
        child: FractionallySizedBox(
          heightFactor: 0.5,
          child: FederationPickerSheet(federations: federations, title: title),
        ),
      );
    },
  );
}

class FederationPickerSheet extends StatefulWidget {
  final List<(FederationSelector, bool)> federations;
  final String? title;

  const FederationPickerSheet({
    super.key,
    required this.federations,
    this.title,
  });

  @override
  State<FederationPickerSheet> createState() => _FederationPickerSheetState();
}

class _FederationPickerSheetState extends State<FederationPickerSheet> {
  late List<FederationPickerItem> _items;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _items =
        widget.federations
            .map(
              (f) => FederationPickerItem(selector: f.$1, isRecovering: f.$2),
            )
            .toList();
    _loadBalances();
  }

  Future<void> _loadBalances() async {
    final updatedItems = <FederationPickerItem>[];

    for (final item in _items) {
      BigInt? bal;
      if (!item.isRecovering) {
        try {
          bal = await balance(federationId: item.selector.federationId);
        } catch (e) {
          AppLogger.instance.error('Failed to load balance: $e');
        }
      }
      updatedItems.add(
        FederationPickerItem(
          selector: item.selector,
          isRecovering: item.isRecovering,
          balanceMsats: bal,
        ),
      );
    }

    if (mounted) {
      setState(() {
        _items = updatedItems;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Grab handle
        Container(
          width: 40,
          height: 4,
          margin: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: Colors.grey[700],
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        // Title
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            widget.title ?? 'Select Federation',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.primary,
            ),
          ),
        ),
        const SizedBox(height: 8),
        // Federation list
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: _items.length,
            itemBuilder: (context, index) {
              final item = _items[index];
              return _FederationPickerTile(
                item: item,
                isLoading: _isLoading,
                onTap: () {
                  Navigator.of(context).pop((item.selector, item.isRecovering));
                },
              );
            },
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }
}

class _FederationPickerTile extends StatelessWidget {
  final FederationPickerItem item;
  final bool isLoading;
  final VoidCallback onTap;

  const _FederationPickerTile({
    required this.item,
    required this.isLoading,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final prefs = context.watch<PreferencesProvider>();

    String balanceText;
    if (item.isRecovering) {
      balanceText = 'Recovering...';
    } else if (isLoading) {
      balanceText = 'Loading...';
    } else if (item.balanceMsats != null) {
      balanceText = formatBalance(
        item.balanceMsats!,
        false,
        prefs.bitcoinDisplay,
      );
    } else {
      balanceText = 'Unknown balance';
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.grey[900],
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    Icons.account_balance,
                    color: theme.colorScheme.primary,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.selector.federationName,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        balanceText,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color:
                              item.isRecovering
                                  ? Colors.amber
                                  : Colors.grey[400],
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: Colors.grey[600]),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
