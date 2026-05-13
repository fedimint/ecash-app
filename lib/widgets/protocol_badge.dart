import 'package:flutter/material.dart';

class ProtocolBadge extends StatelessWidget {
  final bool isLnv2;

  const ProtocolBadge({super.key, required this.isLnv2});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color fg =
        isLnv2
            ? theme.colorScheme.primary
            : theme.colorScheme.onSurface.withOpacity(0.7);
    final Color bg =
        isLnv2
            ? theme.colorScheme.primary.withOpacity(0.15)
            : theme.colorScheme.onSurface.withOpacity(0.10);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        isLnv2 ? 'LNv2' : 'LNv1',
        style: theme.textTheme.labelSmall?.copyWith(
          color: fg,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
