import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/widgets/pin_entry.dart';
import 'package:flutter/material.dart';

class PinLockScreen extends StatelessWidget {
  final VoidCallback onUnlocked;

  const PinLockScreen({super.key, required this.onUnlocked});

  @override
  Widget build(BuildContext context) {
    return PinEntry(
      mode: PinEntryMode.verify,
      onPinSubmitted: (pin) async {
        if (await verifyPin(pin: pin)) {
          onUnlocked();
          return null;
        }
        // Also false while the backoff is running; PinEntry replaces this with
        // the countdown once it re-reads the lockout.
        return context.mounted ? context.l10n.incorrectPin : null;
      },
    );
  }
}
