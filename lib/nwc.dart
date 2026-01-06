import 'dart:io';

import 'package:ecashapp/frb_generated.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/nostr.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';

// TaskHandler for foreground service - calls Rust NWC listener directly
// The TaskHandler cannot have any log statements using `AppLogger`, it will crash
// the foreground task.
class NWCTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    // Initialize RustLib in the foreground task isolate
    await RustLib.init();

    // Get federation data passed when starting the service
    final federationIdStr = await FlutterForegroundTask.getData<String>(
      key: 'federation_id',
    );
    final relay = await FlutterForegroundTask.getData<String>(key: 'relay');

    if (federationIdStr == null || relay == null) {
      return;
    }

    // Call Rust blocking listen function - this will run until the service is stopped
    // The function takes a string federation_id for easier passing from foreground task
    await listenForNwcBlocking(federationIdStr: federationIdStr, relay: relay);
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // No-op - listening is handled by onStart
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {}
}

// Top-level callback function for foreground task
@pragma('vm:entry-point')
void startNWCCallback() {
  FlutterForegroundTask.setTaskHandler(NWCTaskHandler());
}

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

  bool _serviceRunning = false;
  FederationSelector? _connectedFederation;

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

  Future<void> _startForegroundService(
    FederationSelector federation,
    String relay,
  ) async {
    AppLogger.instance.info(
      '[NWC] Starting foreground service for ${federation.federationName} with relay: $relay',
    );

    final hasPermission = await _requestNotificationPermission();
    if (!hasPermission) {
      AppLogger.instance.warn('[NWC] Notification permission denied');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Notification permission required for NWC'),
          ),
        );
      }
      return;
    }

    // Convert FederationId to string for passing to foreground task
    final federationIdStr = await federationIdToString(
      federationId: federation.federationId,
    );
    AppLogger.instance.debug('[NWC] Federation ID string: $federationIdStr');

    // Save data for the task handler
    await FlutterForegroundTask.saveData(
      key: 'federation_id',
      value: federationIdStr,
    );
    await FlutterForegroundTask.saveData(key: 'relay', value: relay);

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
      notificationText: 'Connected to ${federation.federationName}',
      callback: startNWCCallback,
    );

    AppLogger.instance.info('[NWC] Foreground service started successfully');
    setState(() {
      _serviceRunning = true;
      _connectedFederation = federation;
    });
  }

  Future<void> _stopForegroundService() async {
    AppLogger.instance.debug(
      '[NWC] Stopping foreground service (currently running: $_serviceRunning)',
    );
    if (!_serviceRunning) {
      AppLogger.instance.debug('[NWC] Service not running, skipping stop');
      return;
    }

    await FlutterForegroundTask.stopService();
    AppLogger.instance.info('[NWC] Foreground service stopped');
    setState(() {
      _serviceRunning = false;
      _connectedFederation = null;
    });
  }

  Future<void> _disconnect() async {
    AppLogger.instance.info(
      '[NWC] Disconnecting from federation: ${_connectedFederation?.federationName}',
    );
    if (_connectedFederation != null) {
      AppLogger.instance.debug(
        '[NWC] Removing NWC connection info from database',
      );
      await removeNwcConnectionInfo(
        federationId: _connectedFederation!.federationId,
      );
    }
    await _stopForegroundService();

    AppLogger.instance.debug('[NWC] Disconnect complete, clearing _nwc state');
    setState(() {
      _nwc = null;
    });
  }

  Future<void> _initialize() async {
    AppLogger.instance.debug('[NWC] Initializing...');
    final relays = await getRelays();
    final currentConfigs = await getNwcConnectionInfo();
    AppLogger.instance.debug(
      '[NWC] Found ${currentConfigs.length} existing NWC configs',
    );

    FederationSelector? connectedFed;
    String? connectedRelay;
    NWCConnectionInfo? connectedNwc;

    // Only one config should exist (single federation mode)
    if (widget.federations.isNotEmpty && currentConfigs.isNotEmpty) {
      final config = currentConfigs.first;
      AppLogger.instance.debug(
        '[NWC] Existing config for federation: ${config.$1.federationName}',
      );
      final matchingFed =
          widget.federations
              .where(
                (element) =>
                    element.$1.federationName == config.$1.federationName,
              )
              .toList();

      if (matchingFed.isNotEmpty) {
        connectedFed = matchingFed.first.$1;
        connectedRelay = config.$2.relay;
        connectedNwc = config.$2;
        AppLogger.instance.debug(
          '[NWC] Matched federation: ${connectedFed.federationName}',
        );
      }
    }

    setState(() {
      _relays = relays;
      _selectedFederation =
          connectedFed ??
          (widget.federations.isNotEmpty ? widget.federations.first.$1 : null);
      _nwc = connectedNwc;
      _selectedRelay =
          connectedRelay ?? (relays.isNotEmpty ? relays.first.$1 : null);
      _connectedFederation = connectedFed;
      _loading = false;
    });
    AppLogger.instance.debug(
      '[NWC] State initialized. connectedFed: ${connectedFed?.federationName}, selectedFed: ${_selectedFederation?.federationName}',
    );

    // Start foreground service if there's an active connection
    if (connectedFed != null && connectedRelay != null) {
      AppLogger.instance.info(
        '[NWC] Auto-starting foreground service for existing connection',
      );
      await _startForegroundService(connectedFed, connectedRelay);
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
    final isConnected = _connectedFederation != null;
    final isSelectedFederationConnected =
        isConnected &&
        _connectedFederation!.federationName ==
            _selectedFederation?.federationName;

    return Column(
      children: [
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
            setState(() {
              _selectedFederation = value;
              // Clear NWC info if selecting a different federation than what's connected
              if (_connectedFederation?.federationName !=
                  value?.federationName) {
                _nwc = null;
              }
            });
          },
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          decoration: const InputDecoration(labelText: 'Select a Relay'),
          initialValue: _selectedRelay,
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

                    AppLogger.instance.debug(
                      '[NWC] Button pressed. isSelectedFederationConnected: $isSelectedFederationConnected, isConnected: $isConnected',
                    );
                    AppLogger.instance.debug(
                      '[NWC] Selected: ${selectedFed.federationName}, Connected: ${_connectedFederation?.federationName}',
                    );

                    if (isSelectedFederationConnected) {
                      // Disconnect from current federation
                      AppLogger.instance.info(
                        '[NWC] Action: Disconnect from current federation',
                      );
                      await _disconnect();
                    } else {
                      // If connected to a different federation, disconnect first
                      if (isConnected) {
                        AppLogger.instance.info(
                          '[NWC] Action: Disconnect from different federation first',
                        );
                        await _disconnect();
                      }

                      AppLogger.instance.info(
                        '[NWC] Action: Connect to ${selectedFed.federationName}',
                      );
                      // Get the connection info (creates keys if needed)
                      final result = await setNwcConnectionInfo(
                        federationId: selectedFed.federationId,
                        relay: selectedRelay,
                      );
                      AppLogger.instance.debug(
                        '[NWC] setNwcConnectionInfo returned: publicKey=${result.publicKey}',
                      );

                      setState(() {
                        _nwc = result;
                      });

                      // Start the foreground service which will call the Rust listener
                      await _startForegroundService(selectedFed, selectedRelay);
                    }
                  }
                  : null,
          child: Text(
            isSelectedFederationConnected
                ? 'Disconnect'
                : 'Show Connection Info',
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
        appBar: AppBar(title: const Text('Nostr Wallet Connect')),
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'You haven\'t joined any federations yet.\nPlease join one to continue.',
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
