import 'dart:io';

import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/nostr.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';

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

  bool _serviceRunning = false;
  final Set<String> _connectedFederations = {};

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<bool> _requestNotificationPermission() async {
    if (Platform.isAndroid) {
      final status = await Permission.notification.status;
      if (status.isDenied) {
        final result = await Permission.notification.request();
        return result.isGranted;
      }
      return status.isGranted;
    }
    return true; // iOS or other platforms
  }

  Future<void> _startForegroundService() async {
    if (_serviceRunning) return;

    final hasPermission = await _requestNotificationPermission();
    if (!hasPermission) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Notification permission required for NWC'),
          ),
        );
      }
      return;
    }

    // Initialize the service with Android notification options
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'nwc_foreground_service',
        channelName: 'NWC Foreground Service',
        channelDescription:
            'Keeps NWC wallet connections active in the background',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
      ),
    );

    await FlutterForegroundTask.startService(
      serviceId: 256,
      notificationTitle: 'NWC Active',
      notificationText: _buildNotificationText(),
    );

    setState(() => _serviceRunning = true);
  }

  Future<void> _updateForegroundService() async {
    if (!_serviceRunning) return;

    await FlutterForegroundTask.updateService(
      notificationTitle: 'NWC Active',
      notificationText: _buildNotificationText(),
    );
  }

  Future<void> _stopForegroundService() async {
    if (!_serviceRunning) return;

    await FlutterForegroundTask.stopService();
    setState(() => _serviceRunning = false);
  }

  String _buildNotificationText() {
    if (_connectedFederations.isEmpty) return 'No active connections';
    if (_connectedFederations.length == 1) {
      return 'Connected to ${_connectedFederations.first}';
    }
    return 'Connected to ${_connectedFederations.length} federations: ${_connectedFederations.join(", ")}';
  }

  Future<void> _disconnectFederation(FederationSelector federation) async {
    await removeNwcConnectionInfo(federationId: federation.federationId);

    setState(() {
      _connectedFederations.remove(federation.federationName);

      // Remove from existing configs to prevent it from reappearing
      _existingConfigs.removeWhere(
        (config) => config.$1.federationName == federation.federationName,
      );

      // Clear connection info if disconnecting the currently selected federation
      if (federation.federationName == _selectedFederation?.federationName) {
        _nwc = null;
        _selectedFederation = null;
        _selectedRelay = null;
      }
    });

    if (_connectedFederations.isEmpty) {
      await _stopForegroundService();
    } else {
      await _updateForegroundService();
    }
  }

  Future<void> _initialize() async {
    final relays = await getRelays();
    final currentConfig = await getNwcConnectionInfo();
    _existingConfigs = currentConfig;

    // Track which federations are connected
    final connectedFedNames =
        currentConfig.map((c) => c.$1.federationName).toSet();

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
      _connectedFederations.addAll(connectedFedNames);
      _loading = false;
    });

    // Start foreground service if there are active connections
    if (_connectedFederations.isNotEmpty) {
      await _startForegroundService();
    }
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
              _relays.map((relay) {
                final (uri, connected) = relay;
                final statusText = connected ? 'Connected' : 'Disconnected';
                final statusColor =
                    connected ? Colors.greenAccent : Colors.redAccent;

                return DropdownMenuItem<String>(
                  value: uri,
                  child: Row(
                    mainAxisSize:
                        MainAxisSize.min, // prevent unbounded constraint issue
                    children: [
                      Flexible(
                        child: Text(
                          uri,
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(Icons.circle, size: 10, color: statusColor),
                      const SizedBox(width: 4),
                      Text(
                        statusText,
                        style: TextStyle(fontSize: 12, color: statusColor),
                      ),
                    ],
                  ),
                );
              }).toList(),
          onChanged: (value) {
            setState(() => _selectedRelay = value);
          },
        ),
        const SizedBox(height: 24),
        ElevatedButton(
          onPressed:
              (_selectedFederation != null && _selectedRelay != null)
                  ? () async {
                    final selectedFed = _selectedFederation!;
                    final selectedRelay = _selectedRelay!;

                    // Check if this federation is already connected
                    final isConnected = _nwc != null;

                    if (isConnected) {
                      // Disconnect
                      await _disconnectFederation(selectedFed);
                    } else {
                      // Connect
                      final result = await setNwcConnectionInfo(
                        federationId: selectedFed.federationId,
                        relay: selectedRelay,
                      );

                      setState(() {
                        _nwc = result;
                        _connectedFederations.add(selectedFed.federationName);
                      });

                      if (_connectedFederations.length == 1) {
                        await _startForegroundService();
                      } else {
                        await _updateForegroundService();
                      }
                    }
                  }
                  : null,
          child: Text(_nwc != null ? 'Disconnect' : 'Save Connection Info'),
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
        body: SafeArea(
          child: Center(
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
        ),
      );
    }

    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Nostr Wallet Connect')),
        body: SafeArea(child: const Center(child: CircularProgressIndicator())),
      );
    }

    final connectionString =
        _nwc != null
            ? "nostr+walletconnect://${_nwc!.publicKey}?relay=${_nwc!.relay}&secret=${_nwc!.secret}"
            : null;

    return Scaffold(
      appBar: AppBar(title: const Text('Nostr Wallet Connect')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _buildSelectionForm(),
              if (_nwc != null) ...[
                const SizedBox(height: 32),
                AspectRatio(
                  aspectRatio: 1,
                  child: QrImageView(
                    data: connectionString!,
                    version: QrVersions.auto,
                    backgroundColor: Colors.white,
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
                _buildCopyableField(
                  label: 'Public Key',
                  value: _nwc!.publicKey,
                ),
                _buildCopyableField(label: 'Relays', value: _nwc!.relay),
                _buildCopyableField(label: 'Secret', value: _nwc!.secret),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
