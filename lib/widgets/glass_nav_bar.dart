import 'dart:math' as math;
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
  static const double minHeight = 64;
  static const double bottomMargin = 12;
  static const double horizontalMargin = 16;

  // Shared by heightOf() and _GlassNavBarTab so the height math can't drift
  // from what the tab actually lays out.
  static const double _iconSize = 24;
  static const double _labelGap = 2;
  static const double _labelFontSize = 11;
  static const double _labelLineHeight = 1.2;
  static const EdgeInsets _tabPadding = EdgeInsets.all(6);
  static const EdgeInsets _pillPadding = EdgeInsets.symmetric(
    horizontal: 16,
    vertical: 4,
  );

  final int currentIndex;
  final ValueChanged<int> onTap;
  final List<GlassNavBarItem> items;

  const GlassNavBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
    required this.items,
  });

  /// Pill height. Grows with the platform text scale so a large-text label
  /// doesn't overflow the tab.
  static double heightOf(BuildContext context) {
    // Text layout rounds the line box up to a whole pixel; match it.
    final label =
        (MediaQuery.textScalerOf(context).scale(_labelFontSize) *
                _labelLineHeight)
            .ceilToDouble();
    return math.max(
      minHeight,
      _tabPadding.vertical +
          _pillPadding.vertical +
          _iconSize +
          _labelGap +
          label,
    );
  }

  /// Space a scrollable body needs to reserve so its last row can clear the
  /// bar. Includes the bottom safe-area inset the bar floats above.
  static double bodyInset(BuildContext context) =>
      heightOf(context) + bottomMargin + MediaQuery.paddingOf(context).bottom;

  @override
  Widget build(BuildContext context) {
    final height = heightOf(context);
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
    // The label comes from the Text below; setting it here too would make
    // screen readers announce it twice.
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(GlassNavBar.heightOf(context) / 2),
        child: Padding(
          padding: GlassNavBar._tabPadding,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            padding: GlassNavBar._pillPadding,
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
                Icon(item.icon, size: GlassNavBar._iconSize, color: color),
                const SizedBox(height: GlassNavBar._labelGap),
                // A scaled label grows until the tab runs out of width, then
                // shrinks to fit rather than being ellipsized.
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    item.label,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: GlassNavBar._labelFontSize,
                      height: GlassNavBar._labelLineHeight,
                      fontWeight: FontWeight.w600,
                      color: color,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
