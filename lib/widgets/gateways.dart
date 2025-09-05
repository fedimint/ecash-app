import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/theme.dart';
import 'package:ecashapp/utils.dart';
import 'package:ecashapp/widgets/gateway_details.dart';
import 'package:flutter/material.dart';

class GatewaysList extends StatelessWidget {
  final FederationSelector fed;

  const GatewaysList({super.key, required this.fed});

  Future<List<FedimintGateway>> _fetchGateways() async {
    return await listGateways(federationId: fed.federationId);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return FutureBuilder<List<FedimintGateway>>(
      future: _fetchGateways(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        } else if (snapshot.hasError) {
          AppLogger.instance.error("Error loading gateways: ${snapshot.error}");
          return Center(child: Text("Error loading gateways"));
        } else if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return const Center(child: Text("No gateways available"));
        }

        final gateways = snapshot.data!;
        return ListView.builder(
          itemCount: gateways.length,
          itemBuilder: (context, index) {
            final g = gateways[index];
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Theme.of(
                      context,
                    ).colorScheme.primary.withOpacity(0.1),
                    blurRadius: 8,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 16,
                ),
                leading: Icon(
                  Icons.device_hub,
                  color: Theme.of(context).colorScheme.primary,
                ),
                title: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(g.endpoint, style: theme.textTheme.titleSmall),
                    const SizedBox(height: 4),
                    Text(
                      "${formatBalance(g.baseRoutingFee, true)} + ${g.ppmRoutingFee} ppm",
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: Colors.white60,
                      ),
                    ),
                  ],
                ),
                onTap: () {
                  showAppModalBottomSheet(
                    context: context,
                    child: GatewayDetailsSheet(gateway: g),
                  );
                },
              ),
            );
          },
        );
      },
    );
  }
}
