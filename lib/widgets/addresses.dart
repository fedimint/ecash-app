import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/toast.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';
import 'package:ecashapp/lib.dart';
import 'package:flutter/services.dart';
import 'package:ecashapp/extensions/build_context_l10n.dart';

class OnchainAddressesList extends StatefulWidget {
  final FederationSelector fed;
  final VoidCallback updateAddresses;

  const OnchainAddressesList({
    super.key,
    required this.fed,
    required this.updateAddresses,
  });

  @override
  State<OnchainAddressesList> createState() => _OnchainAddressesListState();
}

class _OnchainAddressesListState extends State<OnchainAddressesList> {
  late Future<List<(String, BigInt, BigInt?)>> _addressesFuture;

  @override
  void initState() {
    super.initState();
    _addressesFuture = getAddresses(federationId: widget.fed.federationId);
  }

  String formatSats(BigInt amount) {
    return '${amount.toString()} sats';
  }

  String abbreviateAddress(
    String address, {
    int headLength = 8,
    int tailLength = 8,
  }) {
    if (address.length <= headLength + tailLength) return address;
    final head = address.substring(0, headLength);
    final tail = address.substring(address.length - tailLength);
    return '$head...$tail';
  }

  String? _explorerUrl(String address) {
    switch (widget.fed.network) {
      case 'bitcoin':
        return 'https://mempool.space/address/$address';
      case 'signet':
        return 'https://mutinynet.com/address/$address';
      default:
        return null;
    }
  }

  Future<void> _refreshAddress(BigInt tweakIdx, String address) async {
    try {
      // Call the Rust async function recheckAddress for the given address and federation
      await recheckAddress(
        federationId: widget.fed.federationId,
        tweakIdx: tweakIdx,
      );
      widget.updateAddresses();

      ToastService().show(
        message: context.l10n.recheckedAddress(abbreviateAddress(address)),
        duration: const Duration(seconds: 5),
        onTap: () {},
        icon: Icon(Icons.info),
      );
    } catch (e) {
      AppLogger.instance.error("Failed to refresh address: $e");
      ToastService().show(
        message: context.l10n.failedToRefreshAddress,
        duration: const Duration(seconds: 5),
        onTap: () {},
        icon: Icon(Icons.error),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<(String, BigInt, BigInt?)>>(
      future: _addressesFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        } else if (snapshot.hasError) {
          return Center(
            child: Text(
              context.l10n.failedToLoadAddresses,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          );
        } else if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return Center(
            child: Text(
              context.l10n.noAddressesFound,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          );
        }

        final addresses = snapshot.data!;

        return ListView.builder(
          itemCount: addresses.length,
          itemBuilder: (context, index) {
            final (address, tweakIdx, amount) = addresses[index];
            final explorerUrl = _explorerUrl(address);

            return Card(
              margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(
                  color: Theme.of(context).colorScheme.primary.withOpacity(0.4),
                  width: 1,
                ),
              ),
              color:
                  amount != null
                      ? Theme.of(context).colorScheme.primary.withOpacity(0.1)
                      : Theme.of(context).colorScheme.surface,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Address row with index and buttons
                    Row(
                      children: [
                        Text(
                          '#${tweakIdx.toString()}',
                          style: Theme.of(
                            context,
                          ).textTheme.bodyMedium?.copyWith(
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              final style = Theme.of(context)
                                  .textTheme
                                  .bodyLarge
                                  ?.copyWith(letterSpacing: 0.8);
                              final textPainter = TextPainter(
                                text: TextSpan(text: address, style: style),
                                maxLines: 1,
                                textDirection: TextDirection.ltr,
                              )..layout();
                              final displayText =
                                  textPainter.width > constraints.maxWidth
                                      ? abbreviateAddress(address)
                                      : address;
                              return Text(
                                displayText,
                                style: style,
                                maxLines: 1,
                              );
                            },
                          ),
                        ),
                        const SizedBox(width: 8),

                        // mempool.space link button
                        if (explorerUrl != null)
                          IconButton(
                            tooltip: context.l10n.viewOnMempoolSpace,
                            icon: const Icon(Icons.open_in_new),
                            color: Theme.of(context).colorScheme.secondary,
                            onPressed: () async {
                              final url = Uri.parse(explorerUrl);
                              await showExplorerConfirmation(context, url);
                            },
                          ),

                        // Copy button
                        IconButton(
                          tooltip: context.l10n.copyAddress,
                          icon: const Icon(Icons.copy),
                          color: Theme.of(context).colorScheme.primary,
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: address));
                            ToastService().show(
                              message: context.l10n.addressCopiedToClipboard,
                              duration: const Duration(seconds: 5),
                              onTap: () {},
                              icon: Icon(Icons.check),
                            );
                          },
                        ),

                        // Refresh button
                        IconButton(
                          tooltip: context.l10n.recheckAddress,
                          icon: const Icon(Icons.refresh),
                          color: Theme.of(context).colorScheme.primary,
                          onPressed: () async {
                            await _refreshAddress(tweakIdx, address);
                          },
                        ),
                      ],
                    ),

                    if (amount != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        formatSats(amount),
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}
