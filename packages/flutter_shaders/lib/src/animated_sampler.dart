import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

typedef AnimatedSamplerBuilder = void Function(
  ui.Image image,
  Size size,
  ui.Canvas canvas,
);

// Stub: passes through to child without shader sampling (flutter_shaders
// 0.1.3 uses removed Flutter 3.35+ render layer APIs).
class AnimatedSampler extends StatelessWidget {
  const AnimatedSampler(
    this.builder, {
    required this.child,
    super.key,
    this.enabled = true,
  });

  final AnimatedSamplerBuilder builder;
  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}
