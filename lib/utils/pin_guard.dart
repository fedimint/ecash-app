import 'package:ecashapp/extensions/build_context_l10n.dart';
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

  if (!context.mounted) return false;
  return await promptForCurrentPin(context) != null;
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

  if (!context.mounted) return false;
  return await promptForCurrentPin(context) != null;
}

/// Prompt for the current PIN and return it, or `null` if the user cancelled.
///
/// The PIN comes back because the calls that weaken PIN protection — changing
/// it, or turning off the spending prompt — are re-verified in the core, which
/// needs the plaintext to do so. Verifying here as well keeps the prompt
/// responsive and means a wrong PIN never leaves this screen.
Future<String?> promptForCurrentPin(
  BuildContext context, {
  PinEntryMode mode = PinEntryMode.verify,
}) async {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder:
        (ctx) => Dialog.fullscreen(
          child: PinEntry(
            mode: mode,
            onCancel: () => Navigator.pop(ctx, null),
            onPinSubmitted: (pin) async {
              if (await verifyPin(pin: pin)) {
                if (ctx.mounted) Navigator.pop(ctx, pin);
                return null;
              }
              // `verifyPin` also returns false while the backoff is running;
              // PinEntry re-reads the lockout and shows the countdown instead
              // of this message when that is what happened.
              return ctx.mounted ? ctx.l10n.incorrectPin : null;
            },
          ),
        ),
  );
}
