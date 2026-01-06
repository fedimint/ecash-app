import 'package:ecashapp/db.dart';
import 'package:ecashapp/detail_row.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/providers/preferences_provider.dart';
import 'package:ecashapp/toast.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

class OnChainReceiveContent extends StatefulWidget {
  final FederationSelector fed;

  const OnChainReceiveContent({super.key, required this.fed});

  @override
  State<OnChainReceiveContent> createState() => _OnChainReceiveContentState();
}

class _OnChainReceiveContentState extends State<OnChainReceiveContent> {
  String? _address;
  BigInt? _peginFee;
  bool _isLoading = true;
  bool _addressCopied = false;

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
      final fee = await getPeginFee(federationId: widget.fed.federationId);

      if (!mounted) return;
      setState(() {
        _address = address;
        _peginFee = fee;
        _isLoading = false;
      });
    } catch (e) {
      AppLogger.instance.error(
        "Could not allocate deposit address or fetch peg-in fee: $e",
      );
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
    setState(() {
      _addressCopied = true;
    });
    ToastService().show(
      message: "Address copied to clipboard",
      duration: const Duration(seconds: 5),
      onTap: () {},
      icon: Icon(Icons.check),
    );
    Future.delayed(const Duration(milliseconds: 2000), () {
      if (mounted) {
        setState(() {
          _addressCopied = false;
        });
      }
    });
  }

  List<TextSpan> _formatAddressWithColor(String address, ThemeData theme) {
    // Format address with spacing every 4 characters and alternating colors
    // Following Bitcoin Design Guide recommendations
    final List<TextSpan> spans = [];
    final baseColor = theme.colorScheme.onSurface;
    final alternateColor = theme.colorScheme.onSurface.withValues(alpha: 0.6);

    for (int i = 0; i < address.length; i += 4) {
      final chunk = address.substring(i, (i + 4).clamp(0, address.length));
      final isEvenChunk = (i ~/ 4) % 2 == 0;

      spans.add(
        TextSpan(
          text: chunk,
          style: TextStyle(color: isEvenChunk ? baseColor : alternateColor),
        ),
      );

      // Add space between chunks (except after the last chunk)
      if (i + 4 < address.length) {
        spans.add(TextSpan(text: ' ', style: TextStyle(color: baseColor)));
      }
    }

    return spans;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bitcoinDisplay = context.select<PreferencesProvider, BitcoinDisplay>(
      (prefs) => prefs.bitcoinDisplay,
    );

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

                  // QR code
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

                  // Clickable address with inline copy icon
                  InkWell(
                    onTap: () => _copyToClipboard(_address!),
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: 8,
                        horizontal: 12,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: RichText(
                              textAlign: TextAlign.center,
                              text: TextSpan(
                                children: _formatAddressWithColor(
                                  _address!,
                                  theme,
                                ),
                                style: theme.textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  fontFamily: 'monospace',
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          AnimatedSwitcher(
                            duration: const Duration(milliseconds: 300),
                            transitionBuilder:
                                (child, anim) =>
                                    ScaleTransition(scale: anim, child: child),
                            child:
                                _addressCopied
                                    ? Icon(
                                      Icons.check,
                                      key: const ValueKey('copied'),
                                      size: 20,
                                      color: theme.colorScheme.primary,
                                    )
                                    : Icon(
                                      Icons.copy,
                                      key: const ValueKey('copy'),
                                      size: 20,
                                      color: theme.colorScheme.primary,
                                    ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Fee information card
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainer,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: theme.colorScheme.primary.withOpacity(0.25),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.info_outline,
                              size: 20,
                              color: theme.colorScheme.primary,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Deposit Information',
                              style: theme.textTheme.titleMedium?.copyWith(
                                color: theme.colorScheme.onSurface,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        CopyableDetailRow(
                          label: 'Peg-in Fee',
                          value:
                              _peginFee == null
                                  ? 'Unable to fetch fee'
                                  : _peginFee == BigInt.zero
                                  ? 'No fee configured'
                                  : formatBalance(
                                    _peginFee!,
                                    false,
                                    bitcoinDisplay,
                                  ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'This fee is deducted by the federation when your deposit is claimed.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurface.withOpacity(0.7),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
    );
  }
}
