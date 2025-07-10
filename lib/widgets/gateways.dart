import 'package:carbine/lib.dart';
import 'package:carbine/multimint.dart';
import 'package:flutter/material.dart';

class GatewaysList extends StatelessWidget {
  final FederationSelector fed;

  const GatewaysList({super.key, required this.fed});

  Future<List<FedimintGateway>> _fetchGateways() async {
    return await listGateways(federationId: fed.federationId);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<FedimintGateway>>(
      future: _fetchGateways(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        } else if (snapshot.hasError) {
          return Center(child: Text("Error loading gateways: ${snapshot.error}"));
        } else if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return const Center(child: Text("No gateways available"));
        }

        final gateways = snapshot.data!;
        return ListView.builder(
          itemCount: gateways.length,
          itemBuilder: (context, index) {
            final g = gateways[index];
            return Card(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: ListTile(
                title: Text(g.endpoint),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (g.lightningAlias != null)
                      Text("Alias: ${g.lightningAlias}"),
                    if (g.lightningNode != null)
                      Text("Node: ${g.lightningNode}"),
                    Text("Routing Fee: ${g.baseRoutingFee} sats + ${g.ppmRoutingFee} ppm"),
                    Text("Tx Fee: ${g.baseTransactionFee} sats + ${g.ppmTransactionFee} ppm"),
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
