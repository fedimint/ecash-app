import 'package:carbine/db.dart';
import 'package:carbine/lib.dart';
import 'package:carbine/multimint.dart';
import 'package:carbine/utils.dart';
import 'package:flutter/material.dart';

class LightningAddressScreen extends StatefulWidget {
  final List<(FederationSelector, bool)> federations;

  const LightningAddressScreen({super.key, required this.federations});

  @override
  State<LightningAddressScreen> createState() => _LightningAddressScreenState();
}

class _LightningAddressScreenState extends State<LightningAddressScreen> {
  String lnAddressApi = "http://localhost:8080";
  bool _loading = true;
  FederationSelector? _selectedFederation;

  List<String> _domains = [];
  List<(FederationSelector, LightningAddressConfig)> _existingConfigs = [];

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      final domains = await listLnAddressDomains(lnAddressApi: lnAddressApi);
      final currentConfig = await getLnAddressConfig();
      _existingConfigs = currentConfig;

      // TODO: Add matching logic for current config

      setState(() {
        _domains = domains;
        _loading = false;
      });
    } catch (e) {
      AppLogger.instance.error("Unable to get domains: $e");
      // TODO: Set UI Error message
    }
  }

  Widget _buildSelectionForm() {
    final feds = widget.federations.map((f) => f.$1);
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
            /*
            final match =
                _existingConfigs
                    .where((c) => c.$1.federationName == value?.federationName)
                    .toList();

            setState(() {
              _selectedFederation = value;
              _nwc = match.isNotEmpty ? match.first.$2 : null;
              _selectedRelay = match.isNotEmpty ? match.first.$2.relay : null;
            });
            */
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (widget.federations.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text("Lightning Address")),
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
        appBar: AppBar(title: const Text('Lightning Address')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text("Lightning Address")),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [_buildSelectionForm()],
        ),
      ),
    );
  }
}
