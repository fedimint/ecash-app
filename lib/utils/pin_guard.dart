import 'package:ecashapp/lib.dart';
import 'package:ecashapp/widgets/pin_entry.dart';
import 'package:flutter/material.dart';

/// Prompt for the PIN before a payment leaves the wallet.
///
/// Honours the "require PIN for spending" preference: a user who turned it off
/// has opted into paying without a prompt.
Future<bool> checkSpendingPin(BuildContext context) async {
  final requirePin = await getRequirePinForSpending();
  final hasPin = await hasPinCode();
  if (!requirePin || !hasPin) return true;

  return _promptForPin(context);
}

/// Prompt for the PIN before revealing something that grants access to the
/// funds themselves — the recovery seed above all.
///
/// Deliberately ignores "require PIN for spending". That preference is about
/// payments, and someone who turned it off has not agreed to hand their
/// recovery words to whoever picks up an unlocked phone. Anyone holding the
/// seed can drain every federation, so it is a stricter gate than a payment.
/// With no PIN configured there is nothing to check.
Future<bool> checkPinForSensitiveAction(BuildContext context) async {
  final hasPin = await hasPinCode();
  if (!hasPin) return true;

  return _promptForPin(context);
}

Future<bool> _promptForPin(BuildContext context) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder:
        (ctx) => Dialog.fullscreen(
          child: PinEntry(
            mode: PinEntryMode.verify,
            onCancel: () => Navigator.pop(ctx, false),
            onPinSubmitted: (pin) async {
              final ok = await verifyPin(pin: pin);
              if (ok && ctx.mounted) {
                Navigator.pop(ctx, true);
              }
              return ok;
            },
          ),
        ),
  );

  return result ?? false;
}
