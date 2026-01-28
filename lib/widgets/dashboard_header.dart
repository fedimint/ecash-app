import 'package:flutter/material.dart';
import 'package:ecashapp/multimint.dart';

class DashboardHeader extends StatelessWidget {
  final String name;
  final String? network;
  final List<PeerStatus> peerStatus;

  const DashboardHeader({
    super.key,
    required this.name,
    this.network,
    this.peerStatus = const [],
  });

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      shaderCallback:
          (bounds) => LinearGradient(
            colors: [
              Theme.of(context).colorScheme.primary,
              Theme.of(context).colorScheme.secondary,
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ).createShader(Rect.fromLTWH(0, 0, bounds.width, bounds.height)),
      child: Column(
        children: [
          if (peerStatus.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children:
                    peerStatus.map((peer) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: peer.online ? Colors.green : Colors.red,
                          ),
                        ),
                      );
                    }).toList(),
              ),
            ),
          Text(
            name.toUpperCase(),
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w900,
              letterSpacing: 2,
              color: Colors.white,
              shadows: [
                Shadow(
                  blurRadius: 10,
                  color: Theme.of(context).colorScheme.primary.withOpacity(0.5),
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            textAlign: TextAlign.center,
          ),
          if (network != null && network!.toLowerCase() != 'bitcoin')
            Padding(
              padding: const EdgeInsets.only(top: 8.0),
              child: Text(
                "This is a test network and is not worth anything.",
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.secondary,
                  fontStyle: FontStyle.italic,
                ),
                textAlign: TextAlign.center,
              ),
            ),
        ],
      ),
    );
  }
}
