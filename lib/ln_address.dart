import 'dart:async';
import 'dart:io';

import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/toast.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';

class LightningAddressScreen extends StatefulWidget {
  final List<(FederationSelector, bool)> federations;
  final void Function(FederationSelector fed, bool recovering)
  onLnAddressRegistered;

  const LightningAddressScreen({
    super.key,
    required this.federations,
    required this.onLnAddressRegistered,
  });

  @override
  State<LightningAddressScreen> createState() => _LightningAddressScreenState();
}

class _LightningAddressScreenState extends State<LightningAddressScreen> {
  String _lnAddressApi = "https://ecash.love";
  String _recurringdApi = "https://lnurl.ecash.love";
  bool _loading = true;
  FederationSelector? _selectedFederation;

  List<String> _domains = [];

  String? _selectedDomain;
  final TextEditingController _usernameController = TextEditingController();

  Timer? _debounceTimer;
  LNAddressStatus? _status;
  String? _lastCheckedAddress;

  // Advanced state
  bool _showAdvanced = false;
  bool? _lnAddressApiOnline;
  bool? _recurringdApiOnline;
  final _lnApiController = TextEditingController();
  final _recurringdApiController = TextEditingController();
  bool _registering = false;

  @override
  void initState() {
    super.initState();
    _lnApiController.text = _lnAddressApi;
    _recurringdApiController.text = _recurringdApi;
    _initialize();
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _usernameController.dispose();
    super.dispose();
  }

  Future<void> _updateDomains() async {
    try {
      final domains = await listLnAddressDomains(lnAddressApi: _lnAddressApi);

      setState(() {
        _domains = domains;
        _selectedDomain = (domains.isNotEmpty ? domains.first : null);
        _loading = false;
      });
    } catch (e) {
      AppLogger.instance.error("Unable to get doamins: $e");
      ToastService().show(
        message: "Unable to get Lightning Address domains",
        duration: const Duration(seconds: 5),
        onTap: () {},
        icon: Icon(Icons.error),
      );
      setState(() {
        _domains = [];
      });
    }
  }

  Future<void> _initialize() async {
    _usernameController.addListener(_onUsernameChanged);
    await _updateDomains();

    // Set the selected federation to the first federation
    if (widget.federations.isNotEmpty) {
      for (final fed in widget.federations) {
        if (await _onFederationSet(fed.$1)) {
          break;
        }
      }
    }
  }

  void _onUsernameChanged() {
    if (_debounceTimer?.isActive ?? false) _debounceTimer!.cancel();

    _debounceTimer = Timer(const Duration(milliseconds: 800), () async {
      final username = _usernameController.text.trim();
      final domain = _selectedDomain;

      if (_selectedFederation == null || username.isEmpty || domain == null) {
        setState(() => _status = null);
        return;
      }

      final address = '$username@$domain';
      _lastCheckedAddress = address;
      setState(() => _status = null); // Show spinner or pending

      try {
        final result = await checkLnAddressAvailability(
          username: username,
          domain: domain,
          lnAddressApi: _lnAddressApi,
          recurringdApi: _recurringdApi,
          federationId: _selectedFederation!.federationId,
        );
        // result is true = available, false = taken
        if (_lastCheckedAddress == address) {
          setState(() {
            _status = result;
          });
        }
      } catch (e) {
        AppLogger.instance.error("Error checking availability: $e");
        ToastService().show(
          message: "Unable to get check Lightning Address availability",
          duration: const Duration(seconds: 5),
          onTap: () {},
          icon: Icon(Icons.error),
        );
        if (_lastCheckedAddress == address) {
          setState(() => _status = null);
        }
      }
    });
  }

  Future<void> _onRegisteredPressed() async {
    setState(() => _registering = true);
    try {
      final username = _usernameController.text.trim();
      await registerLnAddress(
        federationId: _selectedFederation!.federationId,
        recurringdApi: _recurringdApi,
        lnAddressApi: _lnAddressApi,
        username: username,
        domain: _selectedDomain!,
      );

      widget.onLnAddressRegistered(_selectedFederation!, false);
      Navigator.of(context).pop();
      ToastService().show(
        message: "Claimed $username@$_selectedDomain",
        duration: const Duration(seconds: 5),
        onTap: () {},
        icon: Icon(Icons.check),
      );
    } catch (e) {
      AppLogger.instance.error("Could not register Lightning Address: $e");
      ToastService().show(
        message: "Could not register Lightning Address",
        duration: const Duration(seconds: 5),
        onTap: () {},
        icon: Icon(Icons.error),
      );
    } finally {
      setState(() => _registering = false);
    }
  }

  Future<bool> _onFederationSet(FederationSelector? fed) async {
    if (fed == null) return false;

    AppLogger.instance.info("Changing federations.... ${fed.federationName}");
    bool hasConfig = false;

    setState(() {
      _selectedFederation = fed;
    });

    try {
      final config = await getLnAddressConfig(federationId: fed.federationId);
      if (config != null) {
        setState(() {
          _selectedDomain = config.domain;
          _usernameController.text = config.username;
        });
        hasConfig = true;
      }

      final meta = await getFederationMeta(federationId: fed.federationId);
      if (meta.recurringdApi != null) {
        setState(() {
          _recurringdApi = meta.recurringdApi!;
          _recurringdApiController.text = _recurringdApi;
        });
      }

      if (meta.lnaddressApi != null) {
        setState(() {
          _lnAddressApi = meta.lnaddressApi!;
          _lnApiController.text = _lnAddressApi;
        });
        await _updateDomains();
      }
    } catch (e) {
      AppLogger.instance.warn(
        "Could not get LN address config or federation meta: $e",
      );
    }

    return hasConfig;
  }

  Widget _buildSelectionForm() {
    final feds = widget.federations.where((f) => !f.$2).map((f) => f.$1);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_domains.isNotEmpty) ...[
          DropdownButtonFormField<FederationSelector>(
            decoration: const InputDecoration(labelText: 'Select a Federation'),
            initialValue: _selectedFederation,
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
              _onFederationSet(value);
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
                  initialValue: _selectedDomain,
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
                    if (_status == null)
                      const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else if (_status is LNAddressStatus_Available)
                      const Icon(Icons.check_circle, color: Colors.green)
                    else
                      const Icon(Icons.cancel, color: Colors.red),
                    const SizedBox(width: 8),
                    Text(
                      () {
                        if (_status == null) {
                          return "Checking availability...";
                        } else if (_status is LNAddressStatus_Available) {
                          return "Available";
                        } else if (_status is LNAddressStatus_Registered) {
                          return "Already registered";
                        } else if (_status is LNAddressStatus_CurrentConfig) {
                          return "This is your current Lightning Address";
                        } else if (_status
                            is LNAddressStatus_UnsupportedFederation) {
                          return "Sorry, this federation is not currently supported";
                        } else if (_status is LNAddressStatus_Invalid) {
                          return "Invalid Lightning Address";
                        } else {
                          return "Unavailable";
                        }
                      }(),
                      style: TextStyle(
                        color: () {
                          if (_status is LNAddressStatus_Available) {
                            return Colors.green;
                          } else if (_status is LNAddressStatus_CurrentConfig ||
                              _status is LNAddressStatus_Registered ||
                              _status
                                  is LNAddressStatus_UnsupportedFederation ||
                              _status is LNAddressStatus_Invalid) {
                            return Colors.red;
                          }
                        }(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 32),
          Center(
            child: ElevatedButton(
              onPressed:
                  (_selectedFederation != null &&
                          _status is LNAddressStatus_Available &&
                          !_registering)
                      ? () {
                        _onRegisteredPressed();
                      }
                      : null,
              child:
                  _registering
                      ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                      : const Text('Register'),
            ),
          ),
          const SizedBox(height: 16),
        ] else ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 24),
            child: Center(
              child: Text(
                "Could not contact Lightning Address Server.",
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 16,
                ),
              ),
            ),
          ),
        ],
        GestureDetector(
          onTap: () {
            setState(() {
              _showAdvanced = !_showAdvanced;
            });
            if (!_showAdvanced) return;
            _checkApiOnline();
          },
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('Advanced'),
              Icon(
                _showAdvanced
                    ? Icons.keyboard_arrow_up
                    : Icons.keyboard_arrow_down,
              ),
            ],
          ),
        ),
        if (_showAdvanced) _buildAdvancedSection(),
      ],
    );
  }

  Widget _buildAdvancedSection() {
    Widget buildRow({
      required String label,
      required TextEditingController controller,
      required VoidCallback onSet,
      required bool? isOnline,
    }) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: controller,
                    decoration: InputDecoration(
                      labelText: label,
                      suffixIcon: Padding(
                        padding: const EdgeInsetsDirectional.only(end: 12),
                        child: () {
                          if (isOnline == null) {
                            return const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            );
                          } else if (isOnline) {
                            return const Icon(
                              Icons.check_circle,
                              color: Colors.green,
                            );
                          } else {
                            return const Icon(Icons.cancel, color: Colors.red);
                          }
                        }(),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Center(
              child: ElevatedButton(
                onPressed: onSet,
                child: Text('Set $label'),
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        buildRow(
          label: 'Lightning Address API',
          controller: _lnApiController,
          onSet: () async {
            setState(() {
              _lnAddressApi = _lnApiController.text;
              _lnAddressApiOnline = null;
            });
            await _checkApiOnline();
            if (_lnAddressApiOnline != null && _lnAddressApiOnline!) {
              await _updateDomains();
              _onUsernameChanged();
            }
          },
          isOnline: _lnAddressApiOnline,
        ),
        buildRow(
          label: 'Recurringd API',
          controller: _recurringdApiController,
          onSet: () {
            setState(() {
              _recurringdApi = _recurringdApiController.text;
              _recurringdApiOnline = null;
            });
            _checkApiOnline();
          },
          isOnline: _recurringdApiOnline,
        ),
      ],
    );
  }

  Future<void> _checkApiOnline() async {
    Future<bool> check(String url) async {
      try {
        AppLogger.instance.info("Checking $url for API online status");
        final uri = Uri.parse(url);
        final res =
            Uri.base.scheme == 'https'
                ? await HttpClient().getUrl(uri).then((req) => req.close())
                : await HttpClient().getUrl(uri).then((req) => req.close());
        return res.statusCode == 200;
      } catch (e) {
        AppLogger.instance.error("Error getting online status $e URL: $url");
        return false;
      }
    }

    String trimSlash(String url) =>
        url.endsWith('/') ? url.substring(0, url.length - 1) : url;

    final lnOnline = await check(trimSlash(_lnAddressApi));
    final recOnline = await check(
      "${trimSlash(_recurringdApi)}/lnv1/federations",
    );
    setState(() {
      _lnAddressApiOnline = lnOnline;
      _recurringdApiOnline = recOnline;
    });
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
