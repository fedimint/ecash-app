import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/toast.dart';
import 'package:ecashapp/utils/pin_guard.dart';
import 'package:ecashapp/widgets/pin_entry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart';

class AccessControlScreen extends StatefulWidget {
  const AccessControlScreen({super.key});

  @override
  State<AccessControlScreen> createState() => _AccessControlScreenState();
}

class _AccessControlScreenState extends State<AccessControlScreen> {
  bool _hasPin = false;
  bool _requireSpending = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final hasPin = await hasPinCode();
    final requireSpending = await getRequirePinForSpending();
    if (mounted) {
      setState(() {
        _hasPin = hasPin;
        _requireSpending = requireSpending;
        _loading = false;
      });
    }
  }

  /// The core's own words for a failure.
  ///
  /// The wrong-PIN and lockout cases are caught and localized before they get
  /// here, so what is left ("PIN must be 4-6 digits", "A PIN is already set")
  /// is both rare and specific — and far better than reporting all of it as
  /// "Incorrect PIN", which sends the user off retyping a correct PIN.
  String _errorMessage(Object e) =>
      e is AnyhowException ? e.message : e.toString();

  void _toast(String message, IconData icon) {
    ToastService().show(
      message: message,
      duration: const Duration(seconds: 3),
      onTap: () {},
      icon: Icon(icon),
    );
  }

  void _setupPin() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder:
            (_) => PinEntry(
              mode: PinEntryMode.setup,
              onCancel: () => Navigator.pop(context),
              onPinSubmitted: (pin) async {
                try {
                  await setPinCode(pin: pin);
                } catch (e) {
                  return _errorMessage(e);
                }
                if (mounted) {
                  Navigator.pop(context);
                  _load();
                  _toast(context.l10n.pinSetSuccessfully, Icons.check);
                }
                return null;
              },
            ),
      ),
    );
  }

  /// Replace the PIN, proving knowledge of the current one first.
  ///
  /// Two prompts rather than one screen: the current PIN is verified up front so
  /// that someone who does not know it never reaches the "choose a new PIN"
  /// step, and a wrong entry there is throttled like any other.
  Future<void> _changePin() async {
    final currentPin = await promptForCurrentPin(
      context,
      mode: PinEntryMode.disable,
    );
    if (currentPin == null || !mounted) return;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder:
            (_) => PinEntry(
              mode: PinEntryMode.setup,
              onCancel: () => Navigator.pop(context),
              onPinSubmitted: (newPin) async {
                try {
                  await changePinCode(currentPin: currentPin, newPin: newPin);
                } catch (e) {
                  return _errorMessage(e);
                }
                if (mounted) {
                  Navigator.pop(context);
                  _load();
                  _toast(context.l10n.pinChangedSuccessfully, Icons.check);
                }
                return null;
              },
            ),
      ),
    );
  }

  Future<void> _removePin() async {
    final pin = await promptForCurrentPin(context, mode: PinEntryMode.disable);
    if (pin == null || !mounted) return;

    try {
      await clearPinCode(pin: pin);
    } catch (e) {
      if (mounted) _toast(_errorMessage(e), Icons.error);
      return;
    }

    if (!mounted) return;
    _load();
    _toast(context.l10n.pinRemoved, Icons.check);
  }

  /// Turning the spending prompt *off* weakens protection, so it costs a PIN;
  /// turning it on does not. The switch is reverted if the prompt is cancelled
  /// or the core rejects the change.
  Future<void> _setRequireSpending(bool value) async {
    String? currentPin;
    if (!value) {
      currentPin = await promptForCurrentPin(context);
      if (currentPin == null) return;
    }

    try {
      await setRequirePinForSpending(require: value, currentPin: currentPin);
    } catch (e) {
      if (mounted) _toast(_errorMessage(e), Icons.error);
      return;
    }

    if (mounted) setState(() => _requireSpending = value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(context.l10n.accessControl)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.accessControl)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            elevation: 2,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.lock, color: theme.colorScheme.primary),
                      const SizedBox(width: 12),
                      Text(
                        context.l10n.pinCode,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _hasPin
                        ? context.l10n.pinEnabledDescription
                        : context.l10n.pinDisabledDescription,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_hasPin) ...[
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _changePin,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: theme.colorScheme.primary,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: Text(context.l10n.changePin),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _hasPin ? _removePin : _setupPin,
                      style: ElevatedButton.styleFrom(
                        backgroundColor:
                            _hasPin
                                ? theme.colorScheme.error
                                : theme.colorScheme.primary,
                        foregroundColor:
                            _hasPin ? theme.colorScheme.onError : Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(
                        _hasPin
                            ? context.l10n.removePin
                            : context.l10n.setUpPin,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            elevation: 2,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: SwitchListTile(
              title: Text(context.l10n.requirePinForSpending),
              subtitle: Text(
                context.l10n.requirePinForSpendingDescription,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              value: _requireSpending,
              onChanged: _hasPin ? _setRequireSpending : null,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 8,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
