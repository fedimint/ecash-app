import 'package:carbine/lib.dart';
import 'package:carbine/multimint.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class OnChainReceive extends StatefulWidget {
  final FederationSelector fed;

  const OnChainReceive({super.key, required this.fed});

  @override
  State<OnChainReceive> createState() => _OnChainReceiveState();
}

class _OnChainReceiveState extends State<OnChainReceive> {
  String? _address;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _fetchAddress();
  }

  Future<void> _fetchAddress() async {
    final address = await allocateDepositAddress(
      federationId: widget.fed.federationId,
    );
    setState(() {
      _address = address;
      _isLoading = false;
    });
  }

  void _copyToClipboard(String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Address copied to clipboard'),
        duration: Duration(milliseconds: 1200),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Receive On-Chain'),
          centerTitle: true,
          automaticallyImplyLeading: true,
        ),
        body: Center(
          child:
              _isLoading
                  ? const CircularProgressIndicator()
                  : Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          'You can use this address to deposit funds to the federation:',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 20),
                        SelectableText(
                          _address!,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 12),
                        ElevatedButton.icon(
                          onPressed: () => _copyToClipboard(_address!),
                          icon: const Icon(Icons.copy, size: 20),
                          label: const Text('Copy address'),
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 10,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
        ),
      ),
    );
  }
}
