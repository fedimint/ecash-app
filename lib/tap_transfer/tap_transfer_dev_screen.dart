import 'dart:async';
import 'dart:typed_data';

import 'package:ecashapp/lib.dart';
import 'package:ecashapp/tap_transfer/ble_tap.dart';
import 'package:ecashapp/tap_transfer/tap_nfc.dart';
import 'package:ecashapp/tap_transfer/tap_receive.dart';
import 'package:ecashapp/tap_transfer.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

/// Debug-only harness for Phase 3 of the NFC + BLE "tap to send" feature.
///
/// Full end-to-end flow: the receiver generates an ephemeral key + rendezvous
/// UUID, publishes them over NFC (HCE) and advertises over BLE; the sender enters
/// reader mode, taps, reads the rendezvous, encrypts with [encryptEcashForTap]
/// for the NFC-delivered pubkey, and streams the blob over BLE. The receiver
/// decrypts with [TapRecipient]. Any text works as the payload — this verifies
/// the handshake + transport + crypto, not reissue (that's Phase 4).
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

  StreamSubscription<BleTapEvent>? _bleSub;
  StreamSubscription<TapRendezvous>? _nfcSub;
  TapRecipient? _recipient;
  _Mode _mode = _Mode.idle;
  bool _sendStarted = false;
  String? _result;

  @override
  void initState() {
    super.initState();
    TapReceive.instance.pause();
    _bleSub = BleTap.events().listen(
      _onBleEvent,
      onError: (e) => _append('ble stream error: $e'),
    );
    _nfcSub = TapNfc.reads().listen(
      _onRendezvous,
      onError: (e) => _append('nfc stream error: $e'),
    );
  }

  @override
  void dispose() {
    _bleSub?.cancel();
    _nfcSub?.cancel();
    BleTap.stop();
    TapNfc.stopPublish();
    TapNfc.stopReader();
    _recipient?.dispose();
    _payloadController.dispose();
    TapReceive.instance.resume();
    super.dispose();
  }

  void _append(String line) {
    if (!mounted) return;
    setState(() => _log.insert(0, line));
  }

  void _onBleEvent(BleTapEvent e) {
    _append(e.toString());
    AppLogger.instance.info("tap ble(rx): $e");
    switch (e.event) {
      case 'received':
        if (_mode == _Mode.receiving && e.data != null) {
          _decryptReceived(e.data!);
        }
        break;
      case 'status':
        if (e.state == 'sent' || e.state == 'confirmed') {
          setState(() => _result = 'Sent (${e.state})');
        }
        break;
      case 'error':
        setState(() => _result = 'Error: ${e.message}');
        break;
    }
  }

  void _onRendezvous(TapRendezvous r) {
    if (_mode != _Mode.sending || _sendStarted) return;
    _sendStarted = true;
    _append('tapped: uuid=${r.uuid} pubkey=${r.pubkey.length}B');
    TapNfc.stopReader();
    try {
      final blob = encryptEcashForTap(
        ecash: _payloadController.text,
        recipientPubkey: r.pubkey,
      );
      _append('encrypted ${blob.length}B, connecting over BLE…');
      BleTap.sendToPeer(r.uuid, blob);
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
    if (!await TapNfc.hceAvailable()) {
      setState(() => _result = 'NFC/HCE unavailable (off or unsupported)');
      return;
    }
    if (!await _ensurePermissions()) return;

    final recipient = TapRecipient();
    _recipient?.dispose();
    _recipient = recipient;
    final pubkey = recipient.publicKey();
    final uuid = TapNfc.randomUuid();
    setState(() {
      _mode = _Mode.receiving;
      _result = 'Waiting for a tap…';
    });
    _append('rendezvous uuid=$uuid pubkey=${pubkey.length}B');
    await TapNfc.publish(TapRendezvous(pubkey: pubkey, uuid: uuid));
    await BleTap.startReceiver(uuid);
  }

  Future<void> _startSend() async {
    if (!await BleTap.isAvailable()) {
      setState(() => _result = 'BLE unavailable (off or unsupported)');
      return;
    }
    if (!await _ensurePermissions()) return;
    _sendStarted = false;
    setState(() {
      _mode = _Mode.sending;
      _result = 'Tap the receiver…';
    });
    await TapNfc.startReader();
  }

  Future<void> _stop() async {
    await BleTap.stop();
    await TapNfc.stopPublish();
    await TapNfc.stopReader();
    _recipient?.dispose();
    _recipient = null;
    _sendStarted = false;
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
