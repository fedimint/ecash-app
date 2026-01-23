import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class NumPadButton extends StatefulWidget {
  final String label;
  final VoidCallback onPressed;
  final Widget? child;
  final bool isSpecial;
  final bool isLoading;

  const NumPadButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.child,
    this.isSpecial = false,
    this.isLoading = false,
  });

  @override
  State<NumPadButton> createState() => _NumPadButtonState();
}

class _NumPadButtonState extends State<NumPadButton>
    with SingleTickerProviderStateMixin {
  static const _vibrantBlue = Color(0xFF42CFFF);

  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  bool _isPressed = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 150),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(
      begin: 1.0,
      end: 0.95,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleTapDown(TapDownDetails details) {
    setState(() => _isPressed = true);
    _controller.forward();
    HapticFeedback.lightImpact();
  }

  void _handleTapUp(TapUpDetails details) {
    widget.onPressed();
    setState(() => _isPressed = false);
    _controller.reverse();
  }

  void _handleTapCancel() {
    setState(() => _isPressed = false);
    _controller.reverse();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: _handleTapDown,
      onTapUp: _handleTapUp,
      onTapCancel: _handleTapCancel,
      behavior: HitTestBehavior.opaque,
      child: ScaleTransition(
        scale: _scaleAnimation,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeInOut,
          decoration: BoxDecoration(
            color:
                _isPressed
                    ? _vibrantBlue.withValues(alpha: 0.15)
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color:
                  _isPressed
                      ? _vibrantBlue.withValues(alpha: 0.3)
                      : Colors.transparent,
              width: 1,
            ),
          ),
          child: Center(
            child:
                widget.isLoading
                    ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.grey,
                      ),
                    )
                    : widget.child ??
                        Text(
                          widget.label,
                          style: TextStyle(
                            fontSize: widget.isSpecial ? 16 : 28,
                            fontWeight: FontWeight.bold,
                            color:
                                widget.isSpecial ? Colors.grey : Colors.white,
                          ),
                        ),
          ),
        ),
      ),
    );
  }
}
