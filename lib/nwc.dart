import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:carbine/lib.dart';
import 'package:carbine/multimint.dart';
import 'package:carbine/nostr.dart';

class NostrWalletConnect extends StatefulWidget {
  final List<(FederationSelector, bool)> federations;

  const NostrWalletConnect({super.key, required this.federations});

  @override
  State<NostrWalletConnect> createState() => _NostrWalletConnectState();
}

class _NostrWalletConnectState extends State<NostrWalletConnect> {
  String? _copiedKey;
  FederationSelector? _selectedFederation;
  String? _selectedRelay;
  bool _loading = true;

  NWCConnectionInfo? _nwc;
  List<(String, bool)> _relays = [];
  List<(FederationSelector, NWCConnectionInfo)> _existingConfigs = [];

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    final relays = await getRelays();
    final currentConfig = await getNwcConnectionInfo();
    _existingConfigs = currentConfig;

    FederationSelector? firstSelector;
    String? firstRelay;
    NWCConnectionInfo? firstNwc;

    if (widget.federations.isNotEmpty && currentConfig.isNotEmpty) {
      final first = currentConfig.first;
      final matchingFed =
          widget.federations
              .where(
                (element) =>
                    element.$1.federationName == first.$1.federationName,
              )
              .toList();

      if (matchingFed.isNotEmpty) {
        firstSelector = matchingFed.first.$1;
        firstRelay = first.$2.relay;
        firstNwc = first.$2;
      }
    }

    setState(() {
      _relays = relays;
      _selectedFederation = firstSelector;
      _nwc = firstNwc;
      _selectedRelay = firstRelay;
      _loading = false;
    });
  }

  Widget _buildCopyableField({required String label, required String value}) {
    final theme = Theme.of(context);
    final isCopied = _copiedKey == label;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: theme.colorScheme.primary.withOpacity(0.4),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    value,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onSurface,
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  icon: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    transitionBuilder:
                        (child, anim) =>
                            ScaleTransition(scale: anim, child: child),
                    child:
                        isCopied
                            ? Icon(
                              Icons.check,
                              key: const ValueKey('copied'),
                              color: theme.colorScheme.primary,
                            )
                            : Icon(
                              Icons.copy,
                              key: const ValueKey('copy'),
                              color: theme.colorScheme.primary,
                            ),
                  ),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: value));
                    setState(() => _copiedKey = label);
                    Future.delayed(const Duration(seconds: 2), () {
                      if (mounted) setState(() => _copiedKey = null);
                    });
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSelectionForm() {
    final feds = widget.federations.map((e) => e.$1);
    return Column(
      children: [
        DropdownButtonFormField<FederationSelector>(
          decoration: const InputDecoration(labelText: 'Select a Federation'),
          value: _selectedFederation,
          items:
              feds
                  .map(
                    (f) => DropdownMenuItem(
                      value: f,
                      child: Text(f.federationName),
                    ),
                  )
                  .toList(),
          onChanged: (value) {
            final match =
                _existingConfigs
                    .where((c) => c.$1.federationName == value?.federationName)
                    .toList();

            setState(() {
              _selectedFederation = value;
              _nwc = match.isNotEmpty ? match.first.$2 : null;
              _selectedRelay = match.isNotEmpty ? match.first.$2.relay : null;
            });
          },
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          decoration: const InputDecoration(labelText: 'Select a Relay'),
          value: _selectedRelay,
          items:
              _relays
                  .map(
                    (relay) => DropdownMenuItem(
                      value: relay.$1,
                      child: Text(relay.$1),
                    ),
                  )
                  .toList(),
          onChanged: (value) {
            setState(() => _selectedRelay = value);
          },
        ),
        const SizedBox(height: 24),
        ElevatedButton(
          onPressed:
              (_selectedFederation != null &&
                      _selectedRelay != null &&
                      (_nwc == null || _selectedRelay != _nwc!.relay))
                  ? () async {
                    final selectedFed = _selectedFederation!;
                    final selectedRelay = _selectedRelay!;

                    final result = await setNwcConnectionInfo(
                      federationId: selectedFed.federationId,
                      relay: selectedRelay,
                    );

                    setState(() {
                      _nwc = result;
                    });
                  }
                  : null,
          child: const Text('Save Connection Info'),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (widget.federations.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Nostr Wallet Connect')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'You haven’t joined any federations yet.\nPlease join one to continue.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurface.withOpacity(0.8),
              ),
            ),
          ),
        ),
      );
    }

    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Nostr Wallet Connect')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final connectionString =
        _nwc != null
            ? "nostr+walletconnect://${_nwc!.publicKey}?relay=${_nwc!.relay}&secret=${_nwc!.secret}"
            : null;

    return Scaffold(
      appBar: AppBar(title: const Text('Nostr Wallet Connect')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _buildSelectionForm(),
            if (_nwc != null) ...[
              const SizedBox(height: 32),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: theme.colorScheme.primary.withOpacity(0.3),
                      blurRadius: 12,
                      spreadRadius: 1,
                    ),
                  ],
                  border: Border.all(
                    color: theme.colorScheme.primary.withOpacity(0.7),
                    width: 1.5,
                  ),
                ),
                child: SizedBox(
                  width: 400,
                  height: 400,
                  child: QrImageView(
                    data: connectionString!,
                    version: QrVersions.auto,
                    backgroundColor: Colors.white,
                    padding: EdgeInsets.zero,
                  ),
                ),
              ),
              const SizedBox(height: 32),
              Text(
                'Scan with your NWC-compatible wallet to connect.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface.withOpacity(0.8),
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              _buildCopyableField(
                label: 'Connection String',
                value: connectionString,
              ),
              _buildCopyableField(label: 'Public Key', value: _nwc!.publicKey),
              _buildCopyableField(label: 'Relays', value: _nwc!.relay),
              _buildCopyableField(label: 'Secret', value: _nwc!.secret),
            ],
          ],
        ),
      ),
    );
  }
}
