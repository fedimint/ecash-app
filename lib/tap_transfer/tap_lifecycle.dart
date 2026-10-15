/// Serializes NFC startup, shutdown, and receiver rotation. Intent changes
/// immediately, so an in-flight startup can stop at its next await boundary.
class TapLifecycle {
  TapLifecycle({
    required this.start,
    required this.stop,
    required this.onError,
  });

  final Future<void> Function(bool Function() isCurrent) start;
  final Future<void> Function() stop;
  final void Function(Object, StackTrace) onError;

  Future<void> _pending = Future.value();
  bool _foreground = false;
  int _pauses = 0;
  int _generation = 0;

  bool get enabled => _foreground && _pauses == 0;

  Future<void> arm() {
    if (_foreground) return _pending;
    _foreground = true;
    return _reconcile();
  }

  Future<void> disarm() {
    _foreground = false;
    return _reconcile();
  }

  Future<void> pause() {
    _pauses++;
    return _reconcile();
  }

  Future<void> resume() {
    if (_pauses > 0) _pauses--;
    return _reconcile();
  }

  Future<void> _reconcile() {
    final generation = ++_generation;
    final shouldStart = enabled;
    return _enqueue(() async {
      bool isCurrent() => generation == _generation && enabled;
      if (!shouldStart) {
        // Always finish a requested shutdown before releasing its caller,
        // even if a later resume is already queued.
        await stop();
      } else if (isCurrent()) {
        await start(isCurrent);
      }
    });
  }

  Future<void> run(Future<void> Function(bool Function()) action) {
    final generation = _generation;
    return _enqueue(() async {
      bool isCurrent() => generation == _generation && enabled;
      if (isCurrent()) await action(isCurrent);
    });
  }

  Future<void> _enqueue(Future<void> Function() action) {
    _pending = _pending.then((_) => action()).catchError(onError);
    return _pending;
  }
}
