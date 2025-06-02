import 'package:carbine/fed_preview.dart';
import 'package:carbine/lib.dart';
import 'package:carbine/multimint.dart';
import 'package:carbine/pay_preview.dart';
import 'package:carbine/redeem_ecash.dart';
import 'package:carbine/theme.dart';
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

  Future<void> _processText(String text) async {
    if (text.startsWith("fed") &&
        !text.startsWith("fedimint") &&
        widget.selectedFed == null) {
      final meta = await getFederationMeta(inviteCode: text);

      final fed = await showCarbineModalBottomSheet(
        context: context,
        child: FederationPreview(
          federationName: meta.$2.federationName,
          inviteCode: meta.$2.inviteCode,
          welcomeMessage: meta.$1.welcome,
          imageUrl: meta.$1.picture,
          joinable: true,
          guardians: meta.$1.guardians,
          network: meta.$2.network!,
        ),
      );

      if (fed != null) {
        await Future.delayed(const Duration(milliseconds: 400));
        Navigator.pop(context, fed);
      }
    } else if (text.startsWith("ln")) {
      if (widget.selectedFed != null) {
        final preview = await paymentPreview(
          federationId: widget.selectedFed!.federationId,
          bolt11: text,
        );
        if (widget.selectedFed!.network != preview.network) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("Cannot pay invoice from different network."),
            ),
          );
          return;
        }
        final bal = await balance(
          federationId: widget.selectedFed!.federationId,
        );
        if (bal < preview.amountMsats) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                "This federation does not have enough funds to pay this invoice",
              ),
            ),
          );
          return;
        }

        showCarbineModalBottomSheet(
          context: context,
          child: PaymentPreviewWidget(
            fed: widget.selectedFed!,
            paymentPreview: preview,
          ),
        );
      }
    } else {
      // TODO: Dont support direct scan yet, fix this later
      if (widget.selectedFed != null) {
        try {
          print('Trying to parse ecash...');
          final amountMsats = await parseEcash(
            federationId: widget.selectedFed!.federationId,
            ecash: text,
          );
          showCarbineModalBottomSheet(
            context: context,
            child: EcashRedeemPrompt(
              fed: widget.selectedFed!,
              ecash: text,
              amount: amountMsats,
            ),
            heightFactor: 0.25,
          );
        } catch (_) {
          print('Could not parse text as ecash');
        }
      } else {
        print("Unknown Text");
      }
    }
  }

  void _onQRCodeScanned(String code) {
    if (_scanned) return;
    setState(() {
      _scanned = true;
    });

    _processText(code);
    Navigator.pop(context);
  }

  Future<void> _pasteFromClipboard() async {
    setState(() {
      _isPasting = true;
    });

    final clipboardData = await Clipboard.getData('text/plain');
    final text = clipboardData?.text ?? '';

    if (text.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("Clipboard is empty")));

      setState(() {
        _isPasting = false;
      });

      return;
    }

    await _processText(text);

    setState(() {
      _isPasting = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Scaffold(
        appBar: AppBar(
          title: const Text(
            'Scan QR',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          centerTitle: true,
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
        body: Stack(
          children: [
            Positioned.fill(
              child: MobileScanner(
                onDetect: (barcode) {
                  final String? code = barcode.raw;
                  if (code != null) {
                    _onQRCodeScanned(code);
                  }
                },
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: ElevatedButton.icon(
                  onPressed: _isPasting ? null : _pasteFromClipboard,
                  icon:
                      _isPasting
                          ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2.0,
                            ),
                          )
                          : const Icon(Icons.paste),
                  label: Text(
                    _isPasting ? "Pasting..." : "Paste from Clipboard",
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
