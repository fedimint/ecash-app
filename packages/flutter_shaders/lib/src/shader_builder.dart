import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

typedef ShaderBuilderCallback = Widget Function(
  BuildContext context,
  ui.FragmentShader shader,
  Widget? child,
);

// Stub: loads and builds a fragment shader program.
class ShaderBuilder extends StatefulWidget {
  const ShaderBuilder({
    required this.assetKey,
    required this.builder,
    this.child,
    super.key,
  });

  final String assetKey;
  final ShaderBuilderCallback builder;
  final Widget? child;

  @override
  State<ShaderBuilder> createState() => _ShaderBuilderState();
}

class _ShaderBuilderState extends State<ShaderBuilder> {
  ui.FragmentShader? _shader;

  @override
  void initState() {
    super.initState();
    _loadShader();
  }

  Future<void> _loadShader() async {
    final program = await ui.FragmentProgram.fromAsset(widget.assetKey);
    if (mounted) {
      setState(() => _shader = program.fragmentShader());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_shader == null) return widget.child ?? const SizedBox.shrink();
    return widget.builder(context, _shader!, widget.child);
  }
}
