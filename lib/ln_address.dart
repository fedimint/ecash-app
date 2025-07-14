import 'dart:async';

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
  final String _lnAddressApi = "http://localhost:8080";
  bool _loading = true;
  FederationSelector? _selectedFederation;

  List<String> _domains = [];
  List<(FederationSelector, LightningAddressConfig)> _existingConfigs = [];

  String? _selectedDomain;
  final TextEditingController _usernameController = TextEditingController();

  Timer? _debounceTimer;
  bool? _isAvailable;
  String? _lastCheckedAddress;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _usernameController.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    _usernameController.addListener(_onUsernameChanged);
    try {
      final domains = await listLnAddressDomains(lnAddressApi: _lnAddressApi);
      final currentConfig = await getLnAddressConfig();
      _existingConfigs = currentConfig;

      setState(() {
        _domains = domains;
        _selectedDomain = domains.isNotEmpty ? domains.first : null;
        _loading = false;
      });
    } catch (e) {
      AppLogger.instance.error("Unable to get domains: $e");
      setState(() {
        _domains = [];
        _loading = false;
      });
    }
  }

  void _onUsernameChanged() {
    if (_debounceTimer?.isActive ?? false) _debounceTimer!.cancel();

    _debounceTimer = Timer(const Duration(milliseconds: 800), () async {
      final username = _usernameController.text.trim();
      final domain = _selectedDomain;

      if (username.isEmpty || domain == null) {
        setState(() => _isAvailable = null);
        return;
      }

      final address = '$username@$domain';
      _lastCheckedAddress = address;
      setState(() => _isAvailable = null); // Show spinner or pending

      try {
        final result = await checkLnAddressAvailability(
          username: username,
          domain: domain,
          lnAddressApi: _lnAddressApi,
        );
        // result is true = available, false = taken
        if (_lastCheckedAddress == address) {
          if (result is LNAddressStatus_Available) {
            setState(() {
              _isAvailable = true;
            });
          } else {
            setState(() {
              _isAvailable = false;
            });
          }
        }
      } catch (e) {
        AppLogger.instance.error("Error checking availability: $e");
        if (_lastCheckedAddress == address) {
          setState(() => _isAvailable = false);
        }
      }
    });
  }

  Widget _buildSelectionForm() {
    final feds = widget.federations.map((f) => f.$1);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
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
            setState(() {
              _selectedFederation = value;
            });
            _onUsernameChanged();
          },
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              flex: 3,
              child: TextFormField(
                controller: _usernameController,
                decoration: const InputDecoration(labelText: 'Username'),
              ),
            ),
            const SizedBox(width: 8),
            const Text('@', style: TextStyle(fontSize: 18)),
            const SizedBox(width: 8),
            Expanded(
              flex: 3,
              child: DropdownButtonFormField<String>(
                decoration: const InputDecoration(labelText: 'Domain'),
                value: _selectedDomain,
                items:
                    _domains
                        .map(
                          (domain) => DropdownMenuItem(
                            value: domain,
                            child: Text(domain),
                          ),
                        )
                        .toList(),
                onChanged: (value) {
                  setState(() {
                    _selectedDomain = value;
                  });
                },
              ),
            ),
          ],
        ),
        if (_usernameController.text.isNotEmpty && _selectedDomain != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_isAvailable == null)
                    const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else if (_isAvailable == true)
                    const Icon(Icons.check_circle, color: Colors.green)
                  else
                    const Icon(Icons.cancel, color: Colors.red),
                  const SizedBox(width: 8),
                  Text(
                    _isAvailable == null
                        ? "Checking availability..."
                        : _isAvailable == true
                        ? "Available"
                        : "Already registered",
                    style: TextStyle(
                      color:
                          _isAvailable == true
                              ? Colors.green
                              : (_isAvailable == false ? Colors.red : null),
                    ),
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 32),
        Center(
          child: ElevatedButton(
            onPressed: () {
              AppLogger.instance.info("Register LNURL and LNAddress");
            },
            child: const Text('Register'),
          ),
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

    if (_domains.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text("Lightning Address")),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'The Lightning Address server is offline.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        ),
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
