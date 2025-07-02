import 'package:carbine/multimint.dart';
import 'package:flutter/material.dart';
import 'package:carbine/lib.dart';

class OnchainAddressesList extends StatefulWidget {
  final FederationSelector fed;

  const OnchainAddressesList({super.key, required this.fed});

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
              'Failed to load addresses',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          );
        } else if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return Center(
            child: Text(
              'No addresses found',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          );
        }

        final addresses = snapshot.data!;

        return ListView.builder(
          itemCount: addresses.length,
          itemBuilder: (context, index) {
            final (address, _, amount) = addresses[index];

            return Card(
              margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
              color: Theme.of(context).colorScheme.surfaceVariant,
              child: ListTile(
                title: SelectableText(
                  address,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                subtitle: amount != null
                    ? Text(
                        formatSats(amount),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: Theme.of(context).colorScheme.primary,
                            ),
                      )
                    : null,
                leading: const Icon(Icons.account_balance_wallet),
              ),
            );
          },
        );
      },
    );
  }
}
