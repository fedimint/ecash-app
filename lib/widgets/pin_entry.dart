import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/widgets/numpad/custom_numpad.dart';

enum PinEntryMode { setup, verify, disable }

class PinEntry extends StatefulWidget {
  final PinEntryMode mode;

  /// Handles a completed PIN entry. Return `null` on success, or the message to
  /// show beneath the dots on failure.
  ///
  /// The message is the caller's because not every failure is a wrong PIN — a
  /// rejected new PIN or a core error reported as "Incorrect PIN" would send the
  /// user off retyping a PIN that was never the problem.
  final Future<String?> Function(String pin)? onPinSubmitted;
  final VoidCallback? onCancel;

  const PinEntry({
    super.key,
    required this.mode,
    this.onPinSubmitted,
    this.onCancel,
  });

  @override
  State<PinEntry> createState() => _PinEntryState();
}

class _PinEntryState extends State<PinEntry> {
  String _pin = '';
  String? _firstPin;
  String? _errorKey;
  String? _errorText;
  bool _confirming = false;
  bool _submitting = false;

  /// Seconds left on the backoff the core applies after repeated wrong PINs.
  /// The core refuses to check the PIN at all while this is running, so the
  /// keypad is disabled to explain why rather than silently rejecting entries.
  int _lockoutSecs = 0;
  Timer? _lockoutTimer;

  bool get _locked => _lockoutSecs > 0;

  @override
  void initState() {
    super.initState();
    // Setup has nothing to verify against, so it is never throttled.
    if (widget.mode != PinEntryMode.setup) {
      _refreshLockout();
    }
  }

  @override
  void dispose() {
    _lockoutTimer?.cancel();
    super.dispose();
  }

  /// Re-read the backoff from the core, which owns it. The countdown below is
  /// only a display: it is never the thing that decides whether entry reopens.
  Future<void> _refreshLockout() async {
    final secs = (await pinLockoutSeconds()).toInt();
    if (!mounted) return;

    setState(() => _lockoutSecs = secs);
    _lockoutTimer?.cancel();
    if (secs == 0) return;

    _lockoutTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() => _lockoutSecs--);
      if (_lockoutSecs <= 0) {
        timer.cancel();
        // Trust the core rather than our own arithmetic on the way out.
        _refreshLockout();
      }
    });
  }

  String _formatLockout(int totalSecs) {
    final minutes = totalSecs ~/ 60;
    final seconds = (totalSecs % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  String _getTitle(BuildContext context) {
    final l10n = context.l10n;
    if (widget.mode == PinEntryMode.setup) {
      return _confirming ? l10n.confirmPin : l10n.enterNewPin;
    }
    if (widget.mode == PinEntryMode.disable) {
      return l10n.enterCurrentPin;
    }
    return l10n.enterPin;
  }

  String _getSubtitle(BuildContext context) {
    final l10n = context.l10n;
    if (widget.mode == PinEntryMode.setup) {
      return _confirming ? l10n.reenterPinToConfirm : l10n.pinDigitsHint;
    }
    return '';
  }

  String? _getErrorText(BuildContext context) {
    final l10n = context.l10n;
    // The lockout outranks a stale "incorrect PIN": it is the reason the next
    // attempt would be refused, and it is the only one with a countdown.
    if (_locked) {
      return l10n.tooManyPinAttempts(_formatLockout(_lockoutSecs));
    }
    if (_errorText != null) return _errorText;
    if (_errorKey == null) return null;
    switch (_errorKey) {
      case 'pinsDoNotMatch':
        return l10n.pinsDoNotMatch;
      default:
        return _errorKey;
    }
  }

  void _onDigit(int digit) {
    if (_pin.length >= 6 || _submitting || _locked) return;
    setState(() {
      _pin += digit.toString();
      _errorKey = null;
      _errorText = null;
    });
  }

  void _onBackspace() {
    if (_pin.isEmpty || _submitting || _locked) return;
    setState(() {
      _pin = _pin.substring(0, _pin.length - 1);
      _errorKey = null;
      _errorText = null;
    });
  }

  Future<void> _onSubmit() async {
    if (_pin.length < 4 || _submitting || _locked) return;

    if (widget.mode == PinEntryMode.setup && !_confirming) {
      setState(() {
        _firstPin = _pin;
        _pin = '';
        _confirming = true;
      });
      return;
    }

    if (widget.mode == PinEntryMode.setup && _confirming) {
      if (_pin != _firstPin) {
        setState(() {
          _errorKey = 'pinsDoNotMatch';
          _pin = '';
          _confirming = false;
          _firstPin = null;
        });
        return;
      }
    }

    final onPinSubmitted = widget.onPinSubmitted;
    if (onPinSubmitted == null) return;

    setState(() {
      _submitting = true;
      _errorKey = null;
      _errorText = null;
    });

    final failure = await onPinSubmitted(_pin);
    if (failure == null || !mounted) return;

    setState(() {
      _errorText = failure;
      _pin = '';
      _submitting = false;
    });

    // That attempt may have been the one that started the backoff.
    if (widget.mode != PinEntryMode.setup) {
      await _refreshLockout();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final title = _getTitle(context);
    final subtitle = _getSubtitle(context);
    final errorText = _getErrorText(context);

    return Scaffold(
      appBar: AppBar(
        leading:
            widget.onCancel != null
                ? IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: widget.onCancel,
                )
                : null,
      ),
      body: SafeArea(
        child: Column(
          children: [
            const Spacer(flex: 1),
            Text(
              title,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.primary,
              ),
            ),
            if (subtitle.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                subtitle,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 32),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(6, (i) {
                final filled = i < _pin.length;
                final active = i < 6 && (i < 4 || i < _pin.length + 1);
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color:
                          filled
                              ? theme.colorScheme.primary
                              : Colors.transparent,
                      border: Border.all(
                        color:
                            active
                                ? theme.colorScheme.primary
                                : theme.colorScheme.onSurfaceVariant
                                    .withOpacity(0.3),
                        width: 2,
                      ),
                    ),
                  ),
                );
              }),
            ),
            if (errorText != null) ...[
              const SizedBox(height: 16),
              Text(
                errorText,
                style: theme.textTheme.bodyMedium?.copyWith(color: Colors.red),
              ),
            ],
            const Spacer(flex: 2),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed:
                      _pin.length >= 4 && !_submitting && !_locked
                          ? _onSubmit
                          : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF42CFFF),
                    foregroundColor: Colors.black,
                    disabledBackgroundColor: const Color(
                      0xFF42CFFF,
                    ).withOpacity(0.3),
                    disabledForegroundColor: Colors.black45,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child:
                      _submitting
                          ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                Colors.black,
                              ),
                            ),
                          )
                          : Text(
                            widget.mode == PinEntryMode.setup && !_confirming
                                ? l10n.continueButton
                                : l10n.confirm,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              // Greyed out and inert during a lockout, so the countdown above
              // reads as the reason rather than as an unrelated warning.
              child: IgnorePointer(
                ignoring: _locked,
                child: Opacity(
                  opacity: _locked ? 0.4 : 1,
                  child: CustomNumPad(
                    onDigitPressed: _onDigit,
                    onBackspace: _onBackspace,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}
