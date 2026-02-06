import 'package:flutter/material.dart';

class DashboardHeader extends StatelessWidget {
  final String name;
  final String? network;
  final VoidCallback? onTap;

  const DashboardHeader({
    super.key,
    required this.name,
    this.network,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: ShaderMask(
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
            Text(
              name.toUpperCase(),
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w900,
                letterSpacing: 2,
                color: Colors.white,
                shadows: [
                  Shadow(
                    blurRadius: 10,
                    color: Theme.of(
                      context,
                    ).colorScheme.primary.withOpacity(0.5),
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
      ),
    );
  }
}
