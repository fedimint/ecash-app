import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/toast.dart';
import 'package:ecashapp/widgets/pin_entry.dart';
import 'package:flutter/material.dart';

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
                  if (mounted) {
                    Navigator.pop(context);
                    _load();
                    ToastService().show(
                      message: context.l10n.pinSetSuccessfully,
                      duration: const Duration(seconds: 3),
                      onTap: () {},
                      icon: const Icon(Icons.check),
                    );
                  }
                  return true;
                } catch (e) {
                  return false;
                }
              },
            ),
      ),
    );
  }

  void _removePin() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder:
            (_) => PinEntry(
              mode: PinEntryMode.disable,
              onCancel: () => Navigator.pop(context),
              onPinSubmitted: (pin) async {
                try {
                  await clearPinCode(pin: pin);
                  if (mounted) {
                    Navigator.pop(context);
                    _load();
                    ToastService().show(
                      message: context.l10n.pinRemoved,
                      duration: const Duration(seconds: 3),
                      onTap: () {},
                      icon: const Icon(Icons.check),
                    );
                  }
                  return true;
                } catch (e) {
                  return false;
                }
              },
            ),
      ),
    );
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
              onChanged:
                  _hasPin
                      ? (value) async {
                        await setRequirePinForSpending(require: value);
                        setState(() => _requireSpending = value);
                      }
                      : null,
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
