import 'package:ecashapp/lib.dart';
import 'package:ecashapp/screens/pin_lock_screen.dart';

import 'package:flutter/material.dart';

enum _LockState { locked, unlocking, unlocked }

class PinGatedApp extends StatefulWidget {
  final bool pinRequired;
  final Widget child;

  const PinGatedApp({
    super.key,
    required this.pinRequired,
    required this.child,
  });

  @override
  State<PinGatedApp> createState() => _PinGatedAppState();
}

class _PinGatedAppState extends State<PinGatedApp>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  _LockState _state = _LockState.unlocked;
  DateTime? _backgroundedAt;
  late final AnimationController _controller;
  late final Animation<double> _fadeAnimation;
  late final Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _state = widget.pinRequired ? _LockState.locked : _LockState.unlocked;
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _fadeAnimation = Tween<double>(
      begin: 1.0,
      end: 0.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInCubic));
    _scaleAnimation = Tween<double>(
      begin: 1.0,
      end: 1.05,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInCubic));
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        setState(() => _state = _LockState.unlocked);
        _controller.reset();
      }
    });
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    _controller.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _backgroundedAt ??= DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      _checkLockOnResume();
      RustLib.instance.api.crateRestartConnections();
    }
  }

  Future<void> _checkLockOnResume() async {
    if (_backgroundedAt == null) return;
    final elapsed = DateTime.now().difference(_backgroundedAt!);
    _backgroundedAt = null;
    if (elapsed.inSeconds > 30) {
      final pinSet = await hasPinCode();
      if (pinSet && mounted) {
        setState(() => _state = _LockState.locked);
      }
    }
  }

  void _unlock() {
    setState(() => _state = _LockState.unlocking);
    _controller.forward();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        if (_state != _LockState.unlocked)
          AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              return IgnorePointer(
                ignoring: _state == _LockState.unlocking,
                child: FadeTransition(
                  opacity: _fadeAnimation,
                  child: ScaleTransition(scale: _scaleAnimation, child: child),
                ),
              );
            },
            child: PinLockScreen(onUnlocked: _unlock),
          ),
      ],
    );
  }
}
