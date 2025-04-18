
import 'package:carbine/lib.dart';
import 'package:flutter/material.dart';

class Dashboard extends StatelessWidget {
  final FederationSelector federation;

  const Dashboard({super.key, required this.federation});

  Future<BigInt> _getFederationBalance() async {
    final bal = await balance(federationId: this.federation.federationId);
    return bal;
  }

  @override
  Widget build(BuildContext context) {
    final name = federation.federationName;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 32),
          Text(
            name,
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),

          FutureBuilder<BigInt>(
            future: _getFederationBalance(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const CircularProgressIndicator();
              } else if (snapshot.hasError) {
                return Text('Error: ${snapshot.error}');
              }

              final balance = snapshot.data ?? 0;

              return Card(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                elevation: 4,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 24),
                  child: Column(
                    children: [
                      const Text(
                        'Balance',
                        style: TextStyle(fontSize: 20, color: Colors.grey),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '$balance msats',
                        style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                              color: Theme.of(context).colorScheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),

          const SizedBox(height: 48),

          LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth > 400;
              return isWide
                  ? Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: () => print("Receive tapped"),
                            icon: const Icon(Icons.download),
                            label: const Text("Receive"),
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 16),
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: () => print("Send tapped"),
                            icon: const Icon(Icons.upload),
                            label: const Text("Send"),
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 16),
                            ),
                          ),
                        ),
                      ],
                    )
                  : Column(
                      children: [
                        ElevatedButton.icon(
                          onPressed: () => print("Receive tapped"),
                          icon: const Icon(Icons.download),
                          label: const Text("Receive"),
                          style: ElevatedButton.styleFrom(
                            minimumSize: const Size.fromHeight(48),
                          ),
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton.icon(
                          onPressed: () => print("Send tapped"),
                          icon: const Icon(Icons.upload),
                          label: const Text("Send"),
                          style: ElevatedButton.styleFrom(
                            minimumSize: const Size.fromHeight(48),
                          ),
                        ),
                      ],
                    );
            },
          ),
        ],
      ),
    );
  }
}