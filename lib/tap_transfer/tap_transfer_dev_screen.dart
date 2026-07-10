import 'dart:async';
import 'dart:typed_data';

import 'package:ecashapp/lib.dart';
import 'package:ecashapp/tap_transfer/ble_tap.dart';
import 'package:ecashapp/tap_transfer.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

/// Debug-only harness for Phase 2 of the NFC + BLE "tap to send" feature.
///
/// Exercises the real end-to-end path minus NFC: one device receives (advertises
/// + serves its ephemeral pubkey), the other sends (scans, reads the pubkey,
/// encrypts with [encryptEcashForTap], and streams the blob over BLE). The
/// receiver decrypts with [TapRecipient]. Any text works as the payload — Phase 2
/// verifies transport + crypto, not reissue.
class TapTransferDevScreen extends StatefulWidget {
  const TapTransferDevScreen({super.key});

  @override
  State<TapTransferDevScreen> createState() => _TapTransferDevScreenState();
}

enum _Mode { idle, receiving, sending }

class _TapTransferDevScreenState extends State<TapTransferDevScreen> {
  final TextEditingController _payloadController = TextEditingController(
    text:
        'fed1-tap-transfer-dev-payload-${DateTime.now().millisecondsSinceEpoch}',
  );
  final List<String> _log = [];

  StreamSubscription<BleTapEvent>? _subscription;
  TapRecipient? _recipient;
  _Mode _mode = _Mode.idle;
  String? _result;

  @override
  void initState() {
    super.initState();
    _subscription = BleTap.events().listen(
      _onEvent,
      onError: (e) => _append('stream error: $e'),
    );
  }

  @override
  void dispose() {
    _subscription?.cancel();
    BleTap.stop();
    _recipient?.dispose();
    _payloadController.dispose();
    super.dispose();
  }

  void _append(String line) {
    if (!mounted) return;
    setState(() => _log.insert(0, line));
  }

  void _onEvent(BleTapEvent e) {
    _append(e.toString());
    switch (e.event) {
      case 'pubkey':
        if (_mode == _Mode.sending && e.data != null) {
          _encryptAndSend(e.data!);
        }
        break;
      case 'received':
        if (_mode == _Mode.receiving && e.data != null) {
          _decryptReceived(e.data!);
        }
        break;
      case 'status':
        if (e.state == 'sent' || e.state == 'confirmed') {
          setState(
            () =>
                _result =
                    'Sent (${e.state}) — ${_payloadController.text.length} chars',
          );
        }
        break;
      case 'error':
        setState(() => _result = 'Error: ${e.message}');
        break;
    }
  }

  void _encryptAndSend(Uint8List pubkey) {
    try {
      final blob = encryptEcashForTap(
        ecash: _payloadController.text,
        recipientPubkey: pubkey,
      );
      _append('encrypted ${blob.length}B, sending…');
      BleTap.sendBlob(blob);
    } catch (e) {
      setState(() => _result = 'Encrypt failed: $e');
    }
  }

  void _decryptReceived(Uint8List blob) {
    final recipient = _recipient;
    if (recipient == null) return;
    try {
      final text = recipient.decrypt(blob: blob);
      setState(() => _result = 'Received & decrypted:\n$text');
    } catch (e) {
      setState(() => _result = 'Decrypt failed: $e');
    }
  }

  Future<bool> _ensurePermissions() async {
    final statuses =
        await [
          Permission.bluetoothScan,
          Permission.bluetoothConnect,
          Permission.bluetoothAdvertise,
        ].request();
    final granted = statuses.values.every((s) => s.isGranted);
    if (!granted) _append('permissions denied: $statuses');
    return granted;
  }

  Future<void> _startReceive() async {
    if (!await BleTap.isAvailable()) {
      setState(() => _result = 'BLE unavailable (off or unsupported)');
      return;
    }
    if (!await _ensurePermissions()) return;
    final recipient = TapRecipient();
    _recipient?.dispose();
    _recipient = recipient;
    final pubkey = recipient.publicKey();
    setState(() {
      _mode = _Mode.receiving;
      _result = 'Waiting for a sender to tap…';
    });
    _append('receiver pubkey ${pubkey.length}B; advertising');
    await BleTap.startReceiver(pubkey);
  }

  Future<void> _startSend() async {
    if (!await BleTap.isAvailable()) {
      setState(() => _result = 'BLE unavailable (off or unsupported)');
      return;
    }
    if (!await _ensurePermissions()) return;
    setState(() {
      _mode = _Mode.sending;
      _result = 'Scanning for a receiver…';
    });
    await BleTap.startSender();
  }

  Future<void> _stop() async {
    await BleTap.stop();
    _recipient?.dispose();
    _recipient = null;
    setState(() {
      _mode = _Mode.idle;
      _result = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final busy = _mode != _Mode.idle;

    return Scaffold(
      appBar: AppBar(title: const Text('Tap transfer (dev)')), // i18n-ignore
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _payloadController,
              enabled: !busy,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Payload to send', // i18n-ignore
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: busy ? null : _startReceive,
                    icon: const Icon(Icons.download),
                    label: const Text('Receive'), // i18n-ignore
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: busy ? null : _startSend,
                    icon: const Icon(Icons.upload),
                    label: const Text('Send'), // i18n-ignore
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: busy ? _stop : null,
              icon: const Icon(Icons.stop),
              label: const Text('Stop'), // i18n-ignore
            ),
            const SizedBox(height: 16),
            if (_result != null)
              Card(
                color: theme.colorScheme.surfaceContainerHighest,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: SelectableText(
                    _result!,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ),
            const SizedBox(height: 16),
            Text('Event log', style: theme.textTheme.titleSmall), // i18n-ignore
            const Divider(),
            Expanded(
              child: ListView.builder(
                itemCount: _log.length,
                itemBuilder:
                    (_, i) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        _log[i],
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
