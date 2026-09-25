import 'package:ecashapp/db.dart';
import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/providers/preferences_provider.dart';
import 'package:ecashapp/utils.dart';
import 'package:ecashapp/widgets/gateway_picker.dart';
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
  bool requireBalance = false,
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
          child: FederationPickerSheet(
            federations: federations,
            title: title,
            requireBalance: requireBalance,
          ),
        ),
      );
    },
  );
}

List<FederationPickerItem> _pickerItems(
  List<(FederationSelector, bool)> federations,
) =>
    federations
        .map((f) => FederationPickerItem(selector: f.$1, isRecovering: f.$2))
        .toList();

Future<List<FederationPickerItem>> _loadPickerBalances(
  List<FederationPickerItem> items,
) async {
  final updatedItems = <FederationPickerItem>[];
  for (final item in items) {
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
  return updatedItems;
}

class FederationPickerSheet extends StatefulWidget {
  final List<(FederationSelector, bool)> federations;
  final String? title;

  /// Disable federations with a zero balance, e.g. when picking one to send
  /// from.
  final bool requireBalance;

  const FederationPickerSheet({
    super.key,
    required this.federations,
    this.title,
    this.requireBalance = false,
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
    _items = _pickerItems(widget.federations);
    _loadBalances();
  }

  Future<void> _loadBalances() async {
    final updatedItems = await _loadPickerBalances(_items);
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
            widget.title ?? context.l10n.selectMint,
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
                requireBalance: widget.requireBalance,
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

  /// Null shows a chevron (tap picks and closes); otherwise a check when true.
  final bool? isSelected;

  /// Disable the tile when the federation has nothing to spend. While
  /// balances load it isn't tappable yet, but isn't dimmed either.
  final bool requireBalance;

  const _FederationPickerTile({
    required this.item,
    required this.isLoading,
    required this.onTap,
    this.isSelected,
    this.requireBalance = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final prefs = context.watch<PreferencesProvider>();

    String balanceText;
    if (item.isRecovering) {
      balanceText = context.l10n.recovering;
    } else if (isLoading) {
      balanceText = context.l10n.loading;
    } else if (item.balanceMsats != null) {
      balanceText = formatBalance(
        item.balanceMsats!,
        false,
        prefs.bitcoinDisplay,
      );
    } else {
      balanceText = context.l10n.unknownBalance;
    }

    final isEmpty =
        requireBalance && !isLoading && item.balanceMsats == BigInt.zero;
    final enabled =
        !item.isRecovering && !isEmpty && !(requireBalance && isLoading);

    return Opacity(
      opacity: item.isRecovering || isEmpty ? 0.5 : 1.0,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Material(
          color: Colors.grey[900],
          // Material asserts on shape + borderRadius together, so the radius
          // lives in the shape.
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side:
                isSelected == true
                    ? BorderSide(color: theme.colorScheme.primary)
                    : BorderSide.none,
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: enabled ? onTap : null,
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
                  if (isSelected == null)
                    Icon(Icons.chevron_right, color: Colors.grey[600])
                  else if (isSelected!)
                    Icon(Icons.check_circle, color: theme.colorScheme.primary),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Result of [showFederationGatewayPicker].
class FederationGatewaySelection {
  final FederationSelector federation;

  /// True when [federation] differs from the one the picker was opened with.
  final bool federationChanged;

  /// Gateways loaded for [federation], so the caller needn't fetch them again.
  final List<FedimintGateway> gateways;
  final FedimintGateway? selectedGateway;

  const FederationGatewaySelection({
    required this.federation,
    required this.federationChanged,
    required this.gateways,
    required this.selectedGateway,
  });
}

/// A picker for a Lightning flow: choose the federation and one of its
/// gateways in the same sheet. Unlike [showFederationPicker], it opens even
/// with a single federation since the gateway can still be changed.
///
/// [gateways] is the list already loaded for [selectedFed] (null if still
/// loading). Resolves null if the sheet is dismissed without pressing Done.
Future<FederationGatewaySelection?> showFederationGatewayPicker({
  required BuildContext context,
  required List<(FederationSelector, bool)> federations,
  required FederationSelector selectedFed,
  required List<FedimintGateway>? gateways,
  required FedimintGateway? selectedGateway,
  String? title,
  bool requireBalance = false,
}) {
  return showModalBottomSheet<FederationGatewaySelection>(
    context: context,
    backgroundColor: Theme.of(context).bottomSheetTheme.backgroundColor,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (context) {
      return SafeArea(
        child: FractionallySizedBox(
          heightFactor: 0.75,
          child: _FederationGatewayPickerSheet(
            federations: federations,
            selectedFed: selectedFed,
            gateways: gateways,
            selectedGateway: selectedGateway,
            title: title,
            requireBalance: requireBalance,
          ),
        ),
      );
    },
  );
}

class _FederationGatewayPickerSheet extends StatefulWidget {
  final List<(FederationSelector, bool)> federations;
  final FederationSelector selectedFed;
  final List<FedimintGateway>? gateways;
  final FedimintGateway? selectedGateway;
  final String? title;
  final bool requireBalance;

  const _FederationGatewayPickerSheet({
    required this.federations,
    required this.selectedFed,
    required this.gateways,
    required this.selectedGateway,
    this.title,
    this.requireBalance = false,
  });

  @override
  State<_FederationGatewayPickerSheet> createState() =>
      _FederationGatewayPickerSheetState();
}

class _FederationGatewayPickerSheetState
    extends State<_FederationGatewayPickerSheet> {
  late List<FederationPickerItem> _items;
  bool _loadingBalances = true;

  // Index of the federation the sheet opened with, and of the highlighted one.
  // Null until resolved (FederationId has no `==`, so it's matched by string);
  // a null highlight means "the federation the sheet opened with".
  int? _initialIndex;
  int? _highlighted;

  // Gateways per federation index; null means loading. Key -1 is the
  // federation the sheet opened with, before its index is resolved.
  final Map<int, List<FedimintGateway>?> _gateways = {};
  FedimintGateway? _selectedGateway;

  int get _currentKey => _highlighted ?? _initialIndex ?? -1;

  @override
  void initState() {
    super.initState();
    _items = _pickerItems(widget.federations);
    _gateways[-1] = widget.gateways;
    _selectedGateway = widget.selectedGateway;
    _resolveInitialIndex();
    _loadBalances();
    if (widget.gateways == null) _fetchGateways(-1, widget.selectedFed);
  }

  Future<void> _resolveInitialIndex() async {
    try {
      final selectedId = await federationIdToString(
        federationId: widget.selectedFed.federationId,
      );
      for (var i = 0; i < _items.length; i++) {
        final id = await federationIdToString(
          federationId: _items[i].selector.federationId,
        );
        if (id == selectedId) {
          if (!mounted) return;
          setState(() {
            _initialIndex = i;
            _gateways[i] ??= _gateways[-1];
          });
          return;
        }
      }
    } catch (e) {
      AppLogger.instance.error('Failed to resolve selected federation: $e');
    }
  }

  Future<void> _loadBalances() async {
    final updatedItems = await _loadPickerBalances(_items);
    if (mounted) {
      setState(() {
        _items = updatedItems;
        _loadingBalances = false;
      });
    }
  }

  Future<void> _fetchGateways(int key, FederationSelector fed) async {
    List<FedimintGateway> list;
    try {
      list = await listGateways(federationId: fed.federationId);
    } catch (e) {
      AppLogger.instance.error('Failed to fetch gateways: $e');
      list = const [];
    }
    if (!mounted) return;
    setState(() {
      _gateways[key] = list;
      if (key == -1 && _initialIndex != null) _gateways[_initialIndex!] = list;
      // Default to the first gateway once the highlighted federation's list
      // arrives, matching the amount screen's default.
      if (key == _currentKey || (key == -1 && _highlighted == null)) {
        _selectedGateway = list.isNotEmpty ? list.first : null;
      }
    });
  }

  void _onFederationTapped(int index) {
    if (index == _currentKey) return;
    setState(() {
      _highlighted = index;
      final cached = _gateways[index];
      _selectedGateway = cached?.isNotEmpty == true ? cached!.first : null;
      if (!_gateways.containsKey(index)) {
        _gateways[index] = null;
        _fetchGateways(index, _items[index].selector);
      }
    });
  }

  void _onDone() {
    final gateways = _gateways[_currentKey] ?? const <FedimintGateway>[];
    final changed = _highlighted != null && _highlighted != _initialIndex;
    Navigator.of(context).pop(
      FederationGatewaySelection(
        federation:
            changed ? _items[_highlighted!].selector : widget.selectedFed,
        federationChanged: changed,
        gateways: gateways,
        selectedGateway: _selectedGateway,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bitcoinDisplay = context.select<PreferencesProvider, BitcoinDisplay>(
      (prefs) => prefs.bitcoinDisplay,
    );
    final gateways = _gateways[_currentKey];
    final sectionStyle = theme.textTheme.titleSmall?.copyWith(
      fontWeight: FontWeight.bold,
      color: Colors.grey[400],
    );

    return Column(
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
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            widget.title ?? context.l10n.selectMint,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.primary,
            ),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              for (var i = 0; i < _items.length; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _FederationPickerTile(
                    item: _items[i],
                    isLoading: _loadingBalances,
                    isSelected: i == _currentKey,
                    requireBalance: widget.requireBalance,
                    onTap: () => _onFederationTapped(i),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                child: Text(context.l10n.gateway, style: sectionStyle),
              ),
              if (gateways == null)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                )
              else if (gateways.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 8,
                  ),
                  child: Text(
                    context.l10n.noGatewaysAvailableShort,
                    style: const TextStyle(color: Colors.grey),
                  ),
                )
              else
                for (final gw in gateways)
                  GatewayTile(
                    gateway: gw,
                    feeText: gatewayRoutingFeeText(gw, bitcoinDisplay),
                    isSelected:
                        _selectedGateway?.endpoint == gw.endpoint &&
                        _selectedGateway?.isLnv2 == gw.isLnv2,
                    onTap: () => setState(() => _selectedGateway = gw),
                  ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              // Wait for the gateway list so Done never returns a half-loaded
              // selection.
              onPressed: gateways == null ? null : _onDone,
              style: ElevatedButton.styleFrom(
                backgroundColor: theme.colorScheme.primary,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: Text(
                context.l10n.done,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
