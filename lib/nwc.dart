import 'dart:io';

import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/frb_generated.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/nostr.dart';
import 'package:ecashapp/toast.dart';
import 'package:ecashapp/utils/pin_guard.dart';
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

    if (federationIdStr == null) {
      return;
    }

    // Call Rust blocking listen function - this will run until the service is stopped
    // The function takes a string federation_id for easier passing from foreground task
    await listenForNwcBlocking(federationIdStr: federationIdStr);
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

  /// Whether the pairing secret is currently on screen.
  ///
  /// The connection string grants full remote `pay_invoice` capability, so it is
  /// treated like the recovery seed rather than like a setting: never rendered
  /// straight from stored config, only after the user asks for it and clears
  /// [checkPinForSensitiveAction]. Reset whenever the pairing goes away, so
  /// re-connecting cannot inherit an earlier reveal.
  bool _secretRevealed = false;

  List<(String, bool)> _relays = [];

  /// Ceiling on a single wallet-connect payment, in sats. Null only while the
  /// screen is still loading.
  int? _maxPaymentSats;

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

  Future<void> _startForegroundService(FederationSelector federation) async {
    if (Platform.isAndroid) {
      AppLogger.instance.info(
        '[NWC] Starting foreground service for ${federation.federationName}',
      );

      final hasPermission = await _requestNotificationPermission();
      if (!hasPermission) {
        AppLogger.instance.warn('[NWC] Notification permission denied');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(context.l10n.notificationPermissionRequired),
            ),
          );
        }
        return;
      }

      // Convert FederationId to string for passing to foreground task
      final federationIdStr = await federationIdToString(
        federationId: federation.federationId,
      );

      // Save data for the task handler
      await FlutterForegroundTask.saveData(
        key: 'federation_id',
        value: federationIdStr,
      );

      // Initialize the service with Android notification options
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'nwc_foreground_service',
          channelName: context.l10n.nwcForegroundService,
          channelDescription: context.l10n.nwcForegroundServiceDescription,
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
        notificationTitle: context.l10n.nwcActive,
        notificationText: context.l10n.nwcConnectedTo(
          federation.federationName,
        ),
        notificationIcon: const NotificationIcon(
          metaDataName: 'com.ecashapp.NOTIFICATION_ICON',
        ),
        callback: startNWCCallback,
      );

      AppLogger.instance.info('[NWC] Foreground service started successfully');
    }

    setState(() {
      _serviceRunning = true;
      _connectedFederation = federation;
    });
  }

  Future<void> _stopForegroundService() async {
    if (Platform.isAndroid) {
      AppLogger.instance.debug(
        '[NWC] Stopping foreground service (currently running: $_serviceRunning)',
      );
      if (!_serviceRunning) {
        AppLogger.instance.debug('[NWC] Service not running, skipping stop');
        return;
      }

      await FlutterForegroundTask.stopService();
      AppLogger.instance.info('[NWC] Foreground service stopped');
    }

    setState(() {
      _serviceRunning = false;
      _connectedFederation = null;
    });
  }

  Future<void> _disconnect() async {
    if (_connectedFederation != null) {
      AppLogger.instance.debug(
        '[NWC] Removing NWC connection info from database',
      );
      await removeNwcConnectionInfo(
        federationId: _connectedFederation!.federationId,
      );
    }
    await _stopForegroundService();

    setState(() {
      _nwc = null;
      _secretRevealed = false;
    });
  }

  /// Change the per-payment ceiling.
  ///
  /// Raising it is gated behind the PIN, lowering it is not — the same rule the
  /// PIN screen uses for the spending prompt. Weakening a protection is the act
  /// worth authenticating; tightening one should never be harder than leaving it
  /// alone, or people will leave it alone.
  Future<void> _editMaxPayment() async {
    final current = _maxPaymentSats;
    if (current == null) return;

    final entered = await showDialog<int>(
      context: context,
      builder: (ctx) => _MaxPaymentDialog(initialSats: current),
    );
    if (entered == null || entered == current) return;

    if (entered > current) {
      if (!mounted) return;
      if (!await checkPinForSensitiveAction(context)) {
        AppLogger.instance.info('[NWC] Limit increase cancelled: PIN not confirmed');
        return;
      }
    }

    try {
      await setNwcMaxPaymentSats(sats: BigInt.from(entered));
      if (!mounted) return;
      setState(() {
        _maxPaymentSats = entered;
      });
    } catch (e) {
      AppLogger.instance.error('[NWC] Could not set max payment: $e');
      if (!mounted) return;
      ToastService().show(
        message: context.l10n.nwcMaxPaymentFailed,
        duration: const Duration(seconds: 5),
        onTap: () {},
        icon: const Icon(Icons.error),
      );
    }
  }

  /// Reveal the pairing secret, behind the PIN when one is configured.
  ///
  /// Uses the sensitive-action gate rather than the spending one: turning off
  /// the spending prompt is a statement about payments the user makes, not
  /// consent to hand a remote-spending credential to whoever picks up the phone.
  Future<void> _revealSecret() async {
    if (!await checkPinForSensitiveAction(context)) {
      AppLogger.instance.info('[NWC] Reveal cancelled: PIN not confirmed');
      return;
    }
    if (!mounted) return;
    setState(() {
      _secretRevealed = true;
    });
  }

  Future<void> _initialize() async {
    AppLogger.instance.debug('[NWC] Initializing...');
    final relays = await getRelays();
    final currentConfigs = await getNwcConnectionInfo();
    final maxPaymentSats = (await getNwcMaxPaymentSats()).toInt();

    FederationSelector? connectedFed;
    String? connectedRelay;
    NWCConnectionInfo? connectedNwc;

    // Only one config should exist (single federation mode)
    if (widget.federations.isNotEmpty && currentConfigs.isNotEmpty) {
      final config = currentConfigs.first;
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
      }
    }

    setState(() {
      _relays = relays;
      _maxPaymentSats = maxPaymentSats;
      _selectedFederation =
          connectedFed ??
          (widget.federations.isNotEmpty ? widget.federations.first.$1 : null);
      _nwc = connectedNwc;
      _selectedRelay =
          connectedRelay ?? (relays.isNotEmpty ? relays.first.$1 : null);
      _connectedFederation = connectedFed;
      _loading = false;
    });

    // Start foreground service if there's an active connection
    if (connectedFed != null && connectedRelay != null) {
      await _startForegroundService(connectedFed);
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
          onChanged:
              _connectedFederation != null
                  ? null
                  : (value) {
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
          decoration: InputDecoration(labelText: context.l10n.selectARelay),
          initialValue: _selectedRelay,
          items:
              _relays.map((relay) {
                final (uri, connected) = relay;
                final statusText =
                    connected
                        ? context.l10n.connected
                        : context.l10n.disconnected;
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
          onChanged:
              _connectedFederation != null
                  ? null
                  : (value) {
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

                    if (isSelectedFederationConnected) {
                      // Disconnect from current federation
                      AppLogger.instance.info(
                        '[NWC] Action: Disconnect from current federation',
                      );
                      await _disconnect();
                    } else {
                      // Creating a pairing hands out remote spending authority,
                      // so it is gated exactly like revealing an existing one.
                      // Asked before the disconnect below, so cancelling here
                      // cannot leave the user unpaired from the federation they
                      // were connected to with nothing to replace it.
                      if (!await checkPinForSensitiveAction(context)) {
                        AppLogger.instance.info(
                          '[NWC] Connect cancelled: PIN not confirmed',
                        );
                        return;
                      }

                      // If connected to a different federation, disconnect first
                      if (isConnected) {
                        AppLogger.instance.info(
                          '[NWC] Action: Disconnect from different federation first',
                        );
                        await _disconnect();
                      }

                      // Get the connection info (creates keys if needed)
                      final result = await setNwcConnectionInfo(
                        federationId: selectedFed.federationId,
                        relay: selectedRelay,
                        isDesktop: Platform.isLinux | Platform.isMacOS,
                      );
                      AppLogger.instance.info(
                        '[NWC] Set config for ${selectedFed.federationName}',
                      );

                      setState(() {
                        _nwc = result;
                        // The PIN was just confirmed above, so showing what was
                        // created needs no second prompt.
                        _secretRevealed = true;
                      });

                      // Start the foreground service which will call the Rust listener on Android
                      await _startForegroundService(selectedFed);
                    }
                  }
                  : null,
          child: Text(
            isSelectedFederationConnected
                ? context.l10n.disconnect
                : context.l10n.showConnectionInfo,
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
        appBar: AppBar(title: Text(context.l10n.nostrWalletConnect)),
        body: SafeArea(
          child: Center(
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
        ),
      );
    }

    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(context.l10n.nostrWalletConnect)),
        body: SafeArea(child: const Center(child: CircularProgressIndicator())),
      );
    }

    final connectionString =
        _nwc != null
            ? "nostr+walletconnect://${_nwc!.publicKey}?relay=${_nwc!.relay}&secret=${_nwc!.secret}"
            : null;

    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.nostrWalletConnect)),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _buildSelectionForm(),
              if (_maxPaymentSats != null) ...[
                const SizedBox(height: 24),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(context.l10n.nwcMaxPaymentTitle),
                  subtitle: Text(
                    context.l10n.nwcMaxPaymentSubtitle(
                      _maxPaymentSats.toString(),
                    ),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _editMaxPayment,
                ),
              ],
              // An existing pairing is loaded into `_nwc` on entry, so without
              // this the secret would already be on screen before anyone asked
              // for it — and gating only the connect button would protect new
              // pairings while leaving every existing one exposed.
              if (_nwc != null && !_secretRevealed) ...[
                const SizedBox(height: 32),
                Text(
                  context.l10n.nwcSecretHiddenBody,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurface.withOpacity(0.8),
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: _revealSecret,
                  icon: const Icon(Icons.visibility_outlined),
                  label: Text(context.l10n.showConnectionInfo),
                ),
              ],
              if (_nwc != null && _secretRevealed) ...[
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
                  context.l10n.scanNwcInstructions,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurface.withOpacity(0.8),
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                _buildCopyableField(
                  label: context.l10n.connectionString,
                  value: connectionString,
                ),
                _buildCopyableField(
                  label: context.l10n.publicKey,
                  value: _nwc!.publicKey,
                ),
                _buildCopyableField(
                  label: context.l10n.relays,
                  value: _nwc!.relay,
                ),
                _buildCopyableField(
                  label: context.l10n.secret,
                  value: _nwc!.secret,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Amount entry for the wallet-connect per-payment ceiling.
///
/// Validates before popping so the caller only ever receives a usable figure:
/// zero is refused in the core too, but catching it here explains why instead of
/// surfacing a failure after the fact.
class _MaxPaymentDialog extends StatefulWidget {
  final int initialSats;

  const _MaxPaymentDialog({required this.initialSats});

  @override
  State<_MaxPaymentDialog> createState() => _MaxPaymentDialogState();
}

class _MaxPaymentDialogState extends State<_MaxPaymentDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialSats.toString(),
  );
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final parsed = int.tryParse(_controller.text.trim());
    if (parsed == null || parsed < 1) {
      setState(() => _error = context.l10n.nwcMaxPaymentInvalid);
      return;
    }
    Navigator.of(context).pop(parsed);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.l10n.nwcMaxPaymentTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.l10n.nwcMaxPaymentDialogBody),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: context.l10n.nwcMaxPaymentField,
              errorText: _error,
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.l10n.cancel),
        ),
        TextButton(onPressed: _submit, child: Text(context.l10n.save)),
      ],
    );
  }
}
