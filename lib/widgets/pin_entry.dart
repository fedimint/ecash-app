import 'package:flutter/material.dart';
import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/widgets/numpad/custom_numpad.dart';

enum PinEntryMode { setup, verify, disable }

class PinEntry extends StatefulWidget {
  final PinEntryMode mode;
  final Future<bool> Function(String pin)? onPinSubmitted;
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
  bool _confirming = false;
  bool _submitting = false;

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
    if (_errorKey == null) return null;
    final l10n = context.l10n;
    switch (_errorKey) {
      case 'pinsDoNotMatch':
        return l10n.pinsDoNotMatch;
      case 'incorrectPin':
        return l10n.incorrectPin;
      default:
        return _errorKey;
    }
  }

  void _onDigit(int digit) {
    if (_pin.length >= 6 || _submitting) return;
    setState(() {
      _pin += digit.toString();
      _errorKey = null;
    });
  }

  void _onBackspace() {
    if (_pin.isEmpty || _submitting) return;
    setState(() {
      _pin = _pin.substring(0, _pin.length - 1);
      _errorKey = null;
    });
  }

  Future<void> _onSubmit() async {
    if (_pin.length < 4 || _submitting) return;

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

    setState(() => _submitting = true);
    final result = await widget.onPinSubmitted?.call(_pin) ?? false;
    if (!result && mounted) {
      setState(() {
        _errorKey = 'incorrectPin';
        _pin = '';
        _submitting = false;
      });
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
                      _pin.length >= 4 && !_submitting ? _onSubmit : null,
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
              child: CustomNumPad(
                onDigitPressed: _onDigit,
                onBackspace: _onBackspace,
              ),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}
