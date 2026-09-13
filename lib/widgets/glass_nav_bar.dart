import 'dart:ui';

import 'package:flutter/material.dart';

class GlassNavBarItem {
  final IconData icon;
  final String label;

  const GlassNavBarItem({required this.icon, required this.label});
}

/// Floating, translucent bottom navigation pill, centred and sized to its
/// tabs rather than spanning the screen. Pair with `Scaffold(extendBody:
/// true)` so the content scrolls behind it; the blur is what sells the effect.
class GlassNavBar extends StatelessWidget {
  static const double height = 64;
  static const double bottomMargin = 12;
  static const double horizontalMargin = 16;

  final int currentIndex;
  final ValueChanged<int> onTap;
  final List<GlassNavBarItem> items;

  const GlassNavBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
    required this.items,
  });

  /// Space a scrollable body needs to reserve so its last row can clear the
  /// bar. Includes the bottom safe-area inset the bar floats above.
  static double bodyInset(BuildContext context) =>
      height + bottomMargin + MediaQuery.paddingOf(context).bottom;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(height / 2);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        horizontalMargin,
        0,
        horizontalMargin,
        bottomMargin + MediaQuery.paddingOf(context).bottom,
      ),
      // heightFactor keeps the slot as tall as the pill; the Scaffold hands
      // bottomNavigationBar loose constraints and Center would fill them.
      child: Center(
        heightFactor: 1,
        child: ClipRRect(
          borderRadius: radius,
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.08),
                borderRadius: radius,
                border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
              ),
              child: DecoratedBox(
                // Specular highlight along the top edge.
                decoration: BoxDecoration(
                  borderRadius: radius,
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: const [0.0, 0.5],
                    colors: [
                      Colors.white.withValues(alpha: 0.14),
                      Colors.white.withValues(alpha: 0.0),
                    ],
                  ),
                ),
                child: SizedBox(
                  height: height,
                  // IntrinsicWidth + Expanded gives every tab the width of the
                  // widest one, so the pill hugs its content with equal cells.
                  child: IntrinsicWidth(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < items.length; i++)
                          Expanded(
                            child: _GlassNavBarTab(
                              item: items[i],
                              selected: i == currentIndex,
                              onTap: () => onTap(i),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GlassNavBarTab extends StatelessWidget {
  final GlassNavBarItem item;
  final bool selected;
  final VoidCallback onTap;

  const _GlassNavBarTab({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final color = selected ? primary : Colors.grey;
    return Semantics(
      button: true,
      selected: selected,
      label: item.label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(GlassNavBar.height / 2),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            decoration: BoxDecoration(
              color:
                  selected
                      ? primary.withValues(alpha: 0.18)
                      : Colors.transparent,
              borderRadius: BorderRadius.circular(26),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(item.icon, size: 24, color: color),
                const SizedBox(height: 2),
                Text(
                  item.label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
