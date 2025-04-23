import 'package:carbine/lib.dart';
import 'package:carbine/pay.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class ScanQRPage extends StatefulWidget {
  final FederationSelector? selectedFed;
  const ScanQRPage({super.key, this.selectedFed});

  @override
  State<ScanQRPage> createState() => _ScanQRPageState();
}

class _ScanQRPageState extends State<ScanQRPage> {
  bool _scanned = false;
  
  void _onQRCodeScanned(String code) {
    if (_scanned) return;
    setState(() {
      _scanned = true;
    });

    print('QR code scanned: $code');
    // TODO: Replace with logic to handle scanned code
    Navigator.pop(context);
  }

  Future<void> _pasteFromClipboard() async {
    final clipboardData = await Clipboard.getData('text/plain');
    final text = clipboardData?.text ?? '';

    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Clipboard is empty")),
      );

      return;
    }

    if (text.startsWith("fed")) {
      print('Pasted from clipboard: $text');
      final selector = await joinFederation(inviteCode: text);
      print('Selector: $selector');
      Navigator.pop(context, selector);
    } else if (text.startsWith("ln")) {
      final paymentPreview = await parseInvoice(bolt11: text);
      if (widget.selectedFed != null) {
        print('Pay invoice with selected fed ${widget.selectedFed!.federationName}');
      } else {
        // find federation that can pay invoice
        final feds = await federations();
        for (int i = 0; i < feds.length; i++) {
          final currFed = feds[i];
          final fedId = currFed.federationId;
          final bal = await balance(federationId: fedId);
          if (currFed.network == paymentPreview.network && bal > paymentPreview.amount) {
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => Pay(
                  fed: currFed,
                  paymentPreview: paymentPreview,
                ),
              ),
            );
            Navigator.pop(context, currFed);
            return;
          }
        }
      }
    } else {
      print('Unknown text');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Scan")),
      body: Column(
        children: [
          Expanded(
            child: MobileScanner(
              onDetect: (barcode) {
                final String? code = barcode.raw;
                if (code != null) {
                  _onQRCodeScanned(code);
                }
              },
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: ElevatedButton.icon(
              onPressed: _pasteFromClipboard,
              icon: const Icon(Icons.paste),
              label: const Text("Paste from Clipboard"),
            ),
          ),
        ],
      ),
    );
  }
}