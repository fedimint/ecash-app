import 'dart:async';
import 'dart:io';

import 'package:ecashapp/db.dart';
import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/toast.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';

class LightningAddressScreen extends StatefulWidget {
  final List<(FederationSelector, bool)> federations;

  /// Called once the address for [fed] has been registered or removed, so the
  /// app refreshes what it shows for that federation.
  final void Function(FederationSelector fed, bool recovering)
  onLnAddressChanged;

  /// Federation to open on, as its id string, when the caller has one in
  /// mind. Otherwise the first federation with an address is selected.
  final String? initialFederationId;

  const LightningAddressScreen({
    super.key,
    required this.federations,
    required this.onLnAddressChanged,
    this.initialFederationId,
  });

  @override
  State<LightningAddressScreen> createState() => _LightningAddressScreenState();
}

class _LightningAddressScreenState extends State<LightningAddressScreen> {
  String _lnAddressApi = "https://ecash.love";
  String _recurringdApi = "https://recurring.ecash.love";
  final String _lnv1Api = "https://lnurl.ecash.love";
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
  bool _removing = false;

  /// The address currently registered for the selected federation, if any.
  /// Only then is there something to remove.
  LightningAddressConfig? _existingConfig;

  /// Federations whose guardians have set a shutdown date, read for every
  /// federation before the form can show, so the registration lock never
  /// depends on which federation was selected last or by whom. Keyed by the
  /// same instances the dropdown offers.
  final Set<FederationSelector> _expiringFederations = {};

  /// True while the selected federation is shutting down: new registrations
  /// are closed and only removal stays available.
  bool get _selectedFederationExpiring =>
      _expiringFederations.contains(_selectedFederation);

  /// Set once the user picks a federation, so the initializer's sweep through
  /// the list stops overriding that choice.
  bool _userPickedFederation = false;

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
        message: context.l10n.unableToGetDomains,
        duration: const Duration(seconds: 5),
        onTap: () {},
        icon: Icon(Icons.error),
      );
      setState(() {
        _domains = [];
      });
    }
  }

  /// Whether [fed]'s guardians have set a shutdown date. Unreadable meta
  /// counts as not shutting down, which is how the screen behaved before.
  Future<bool> _isExpiring(FederationSelector fed) async {
    try {
      final meta = await getFederationMeta(federationId: fed.federationId);
      return meta.expiryTimestamp != null;
    } catch (e) {
      AppLogger.instance.warn("Could not read federation meta: $e");
      return false;
    }
  }

  Future<void> _initialize() async {
    _usernameController.addListener(_onUsernameChanged);

    // Before the form can show: which federations are shutting down.
    final candidates = [
      for (final (fed, recovering) in widget.federations)
        if (!recovering) fed,
    ];
    final expiring = await Future.wait(candidates.map(_isExpiring));
    if (!mounted) return;
    setState(() {
      for (final (index, fed) in candidates.indexed) {
        if (expiring[index]) _expiringFederations.add(fed);
      }
    });

    await _updateDomains();

    // The caller's federation, if it named one the dropdown can show.
    final wanted = widget.initialFederationId;
    if (wanted != null) {
      for (final (fed, recovering) in widget.federations) {
        if (recovering || _userPickedFederation) continue;
        final id = await federationIdToString(federationId: fed.federationId);
        if (id == wanted) {
          await _onFederationSet(fed);
          return;
        }
      }
    }

    // Otherwise the first federation that already has an address.
    if (widget.federations.isNotEmpty) {
      for (final fed in widget.federations) {
        // A choice the user made meanwhile wins over this sweep.
        if (_userPickedFederation) break;
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
          recurringdApi: _lnv1Api,
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
          message: context.l10n.unableToCheckAvailability,
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
    if (_selectedFederationExpiring) return;
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

      widget.onLnAddressChanged(_selectedFederation!, false);
      Navigator.of(context).pop();
      ToastService().show(
        message: context.l10n.claimedAddress("$username@$_selectedDomain"),
        duration: const Duration(seconds: 5),
        onTap: () {},
        icon: Icon(Icons.check),
      );
    } catch (e) {
      AppLogger.instance.error("Could not register Lightning Address: $e");
      ToastService().show(
        message: context.l10n.couldNotRegisterLnAddress,
        duration: const Duration(seconds: 5),
        onTap: () {},
        icon: Icon(Icons.error),
      );
    } finally {
      setState(() => _registering = false);
    }
  }

  /// Gives up the selected federation's address after an explicit
  /// confirmation: the name stops working at once and anyone may claim it.
  Future<void> _onRemovePressed() async {
    final fed = _selectedFederation;
    final config = _existingConfig;
    if (fed == null || config == null) return;
    final address = '${config.username}@${config.domain}';

    final confirmed = await confirmExternalRequest(
      context,
      title: context.l10n.removeLnAddressConfirmTitle,
      body: context.l10n.removeLnAddressConfirmBody(address),
      confirmLabel: context.l10n.remove,
    );
    if (!confirmed || !mounted) return;

    setState(() => _removing = true);
    try {
      await removeLnAddress(
        federationId: fed.federationId,
        lnAddressApi: _lnAddressApi,
      );
      if (!mounted) return;
      widget.onLnAddressChanged(fed, false);
      Navigator.of(context).pop();
      ToastService().show(
        message: context.l10n.removedAddress(address),
        duration: const Duration(seconds: 5),
        onTap: () {},
        icon: const Icon(Icons.check),
      );
    } catch (e) {
      AppLogger.instance.error("Could not remove Lightning Address: $e");
      if (!mounted) return;
      ToastService().show(
        message: context.l10n.couldNotRemoveLnAddress,
        duration: const Duration(seconds: 5),
        onTap: () {},
        icon: const Icon(Icons.error),
      );
    } finally {
      if (mounted) setState(() => _removing = false);
    }
  }

  Future<bool> _onFederationSet(FederationSelector? fed) async {
    if (fed == null) return false;

    AppLogger.instance.info("Changing federations.... ${fed.federationName}");
    bool hasConfig = false;

    setState(() {
      _selectedFederation = fed;
      _existingConfig = null;
    });

    try {
      final config = await getLnAddressConfig(federationId: fed.federationId);
      // The user may have picked another federation while this one loaded;
      // its result must not land on the one now selected.
      if (!mounted || _selectedFederation != fed) return false;
      if (config != null) {
        setState(() {
          _existingConfig = config;
          _selectedDomain = config.domain;
          _usernameController.text = config.username;
        });
        hasConfig = true;
      }

      final meta = await getFederationMeta(federationId: fed.federationId);
      if (!mounted || _selectedFederation != fed) return hasConfig;
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
            // A form field reads initialValue once, so it is recreated when
            // the selection changes under it; otherwise the initializer's
            // pick was never shown and the field looked unset.
            key: ValueKey(_selectedFederation),
            decoration: InputDecoration(
              labelText: context.l10n.selectAFederation,
            ),
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
              _userPickedFederation = true;
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
                  enabled: !_selectedFederationExpiring,
                  decoration: InputDecoration(labelText: context.l10n.username),
                ),
              ),
              const SizedBox(width: 8),
              const Text('@', style: TextStyle(fontSize: 18)),
              const SizedBox(width: 8),
              Expanded(
                flex: 3,
                child: DropdownButtonFormField<String>(
                  decoration: InputDecoration(
                    labelText: context.l10n.domainLabel,
                  ),
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
                  onChanged:
                      _selectedFederationExpiring
                          ? null
                          : (value) {
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
                          return context.l10n.checkingAvailability;
                        } else if (_status is LNAddressStatus_Available) {
                          return context.l10n.available;
                        } else if (_status is LNAddressStatus_Registered) {
                          return context.l10n.alreadyRegistered;
                        } else if (_status is LNAddressStatus_CurrentConfig) {
                          return context.l10n.currentLightningAddress;
                        } else if (_status
                            is LNAddressStatus_UnsupportedFederation) {
                          return context.l10n.unsupportedFederation;
                        } else if (_status is LNAddressStatus_Invalid) {
                          return context.l10n.invalidLightningAddress;
                        } else {
                          return context.l10n.unavailable;
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
          if (_selectedFederationExpiring)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(
                _existingConfig != null
                    ? context.l10n.lnAddressRemoveCurrent
                    : context.l10n.lnAddressRegistrationClosed,
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 32),
          Center(
            child: ElevatedButton(
              onPressed:
                  (_selectedFederation != null &&
                          _status is LNAddressStatus_Available &&
                          !_selectedFederationExpiring &&
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
                      : Text(context.l10n.register),
            ),
          ),
          if (_existingConfig != null) ...[
            const SizedBox(height: 12),
            Center(
              child: TextButton.icon(
                onPressed: _removing ? null : _onRemovePressed,
                icon: const Icon(Icons.delete_outline),
                label:
                    _removing
                        ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                        : Text(context.l10n.removeLnAddress),
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
        ] else ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 24),
            child: Center(
              child: Text(
                context.l10n.couldNotContactServer,
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
              Text(context.l10n.advanced),
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
                child: Text(context.l10n.setLabel(label)),
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
          label: context.l10n.lightningAddressApi,
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
          label: context.l10n.recurringdApi,
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
    final recOnline = await check(trimSlash(_recurringdApi));
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
        appBar: AppBar(title: Text(context.l10n.lightningAddressTitle)),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              context.l10n.noFederationsJoined,
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
        appBar: AppBar(title: Text(context.l10n.lightningAddressTitle)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.lightningAddressTitle)),
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
