import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/toast.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

class OnChainReceiveContent extends StatefulWidget {
  final FederationSelector fed;

  const OnChainReceiveContent({super.key, required this.fed});

  @override
  State<OnChainReceiveContent> createState() => _OnChainReceiveContentState();
}

class _OnChainReceiveContentState extends State<OnChainReceiveContent> {
  String? _address;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _fetchAddress();
  }

  Future<void> _fetchAddress() async {
    try {
      final address = await allocateDepositAddress(
        federationId: widget.fed.federationId,
      );
      if (!mounted) return;
      setState(() {
        _address = address;
        _isLoading = false;
      });
    } catch (e) {
      AppLogger.instance.error("Could not allocate deposit address: $e");
      ToastService().show(
        message: "Could not get new address",
        duration: const Duration(seconds: 5),
        onTap: () {},
        icon: Icon(Icons.error),
      );
      Navigator.of(context).pop();
    }
  }

  void _copyToClipboard(String text) {
    Clipboard.setData(ClipboardData(text: text));
    ToastService().show(
      message: "Address copied to clipboard",
      duration: const Duration(seconds: 5),
      onTap: () {},
      icon: Icon(Icons.check),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child:
          _isLoading
              ? const Center(child: CircularProgressIndicator())
              : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment:
                    CrossAxisAlignment.stretch, // Stretch children
                children: [
                  Text(
                    'You can use this address to deposit funds to the federation:',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 20),
                  SelectableText(
                    _address!,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 24),
                  AspectRatio(
                    aspectRatio: 1,
                    child: GestureDetector(
                      onTap: () {
                        showDialog(
                          context: context,
                          builder:
                              (_) => Dialog(
                                backgroundColor: Colors.transparent,
                                insetPadding: EdgeInsets.zero,
                                child: GestureDetector(
                                  onTap:
                                      () =>
                                          Navigator.of(
                                            context,
                                            rootNavigator: true,
                                          ).pop(),
                                  child: Container(
                                    width: double.infinity,
                                    height: double.infinity,
                                    color: Colors.black.withOpacity(0.9),
                                    child: Center(
                                      child: QrImageView(
                                        data: _address!,
                                        version: QrVersions.auto,
                                        backgroundColor: Colors.white,
                                        size:
                                            MediaQuery.of(context).size.width *
                                            0.9,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                        );
                      },
                      child: QrImageView(
                        data: _address!,
                        version: QrVersions.auto,
                        backgroundColor: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () {
                        _copyToClipboard(_address!);
                        Navigator.of(context).pop();
                      },
                      icon: const Icon(Icons.copy, size: 20),
                      label: const Text('Copy address'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: theme.colorScheme.primary,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
    );
  }
}
