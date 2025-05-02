import 'package:carbine/fed_preview.dart';
import 'package:carbine/lib.dart';
import 'package:carbine/pay_preview.dart';
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
  bool _isPasting = false;
  
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
    setState(() {
      _isPasting = true;
    });
    final clipboardData = await Clipboard.getData('text/plain');
    final text = clipboardData?.text ?? '';

    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Clipboard is empty")),
      );

      return;
    }

    if (text.startsWith("fed") && !text.startsWith("fedimint") && widget.selectedFed == null) {
      final meta = await getFederationMeta(inviteCode: text);
      final fed = await showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        builder: (_) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
          child: Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: FederationPreview(
              federationName: meta.$2.federationName,
              inviteCode: meta.$2.inviteCode,
              welcomeMessage: meta.$1.welcome,
              imageUrl: meta.$1.picture,
              joinable: true,
              guardians: meta.$1.guardians,
              network: meta.$2.network,
            ),
          ),
        ),
      );

      setState(() {
        _isPasting = false;
      });

      if (fed != null) {
        await Future.delayed(const Duration(milliseconds: 400));
        Navigator.pop(context, fed);
      }
    } else if (text.startsWith("ln")) { 
      final paymentPreview = await parseInvoice(bolt11: text);
      if (widget.selectedFed != null) {
        if (widget.selectedFed!.network != paymentPreview.network) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Cannot pay invoice from different network.")),
          );
          setState(() {
            _isPasting = false;
          });
          return;
        }
        final bal = await balance(federationId: widget.selectedFed!.federationId);
        if (bal < paymentPreview.amount) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("This federation does not have enough funds to pay this invoice")),
          );
          setState(() {
            _isPasting = false;
          });
          return;
        }

        showModalBottomSheet(
          context: context,
          isScrollControlled: true,
          builder: (context) => SizedBox(
            height: MediaQuery.of(context).size.height,
            child: PaymentPreviewWidget(fed: widget.selectedFed!, paymentPreview: paymentPreview),
          ),
        );
        setState(() {
          _isPasting = false;
        });
      } else {
        // find federation that can pay invoice
        /*
        final feds = await federations();
        for (int i = 0; i < feds.length; i++) {
          final currFed = feds[i];
          final fedId = currFed.federationId;
          final bal = await balance(federationId: fedId);
          if (currFed.network == paymentPreview.network && bal > paymentPreview.amount) {
            showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              builder: (context) => SizedBox(
                height: MediaQuery.of(context).size.height,
                child: PaymentPreviewWidget(fed: widget.selectedFed!, paymentPreview: paymentPreview),
              ),
            );
            return;
          }
        }
        */
      }
    } else {
      print('Unknown text');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: const Text('Scan QR', style: TextStyle(fontWeight: FontWeight.bold)),
          centerTitle: true,
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
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
              onPressed: _isPasting ? null : _pasteFromClipboard,
              icon: _isPasting
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2.0,
                      ),
                    )
                  : const Icon(Icons.paste),
              label: Text(_isPasting ? "Pasting..." : "Paste from Clipboard"),
            ),
          ),
        ],
      ),
    );
  }
}