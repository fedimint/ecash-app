import 'package:carbine/lib.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class JoinFederationPage extends StatefulWidget {
  const JoinFederationPage({super.key});

  @override
  State<JoinFederationPage> createState() => _JoinFederationPageState();
}

class _JoinFederationPageState extends State<JoinFederationPage> {
  bool _scanned = false;
  
  void _onQRCodeScanned(String code) {
    if (_scanned) return;
    setState(() {
      _scanned = true;
    });

    print('QR code scanned: $code');
    // Replace with logic to handle scanned code
    Navigator.pop(context);
  }

  Future<void> _pasteFromClipboard() async {
    final clipboardData = await Clipboard.getData('text/plain');
    final text = clipboardData?.text ?? '';

    if (text.isNotEmpty) {
      print('Pasted from clipboard: $text');
      final selector = await joinFederation(inviteCode: text);
      print('Selector: $selector');
      Navigator.pop(context, selector);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Clipboard is empty")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Join Federation")),
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