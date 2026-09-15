import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/lib.dart';
import 'package:ecashapp/multimint.dart';
import 'package:ecashapp/nwc.dart';
import 'package:ecashapp/providers/preferences_provider.dart';
import 'package:ecashapp/toast.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// Confirms leaving [fed], warning about any balance still held there, then
/// leaves: the client is torn down, the federation's NWC listener stopped, the
/// invite-code backup refreshed and [onLeaveFederation] told. Every route above
/// the first is popped afterwards, since the screens beneath belonged to a
/// federation that no longer exists.
///
/// Shared by the federation info screen and the shutdown checklist.
Future<void> showLeaveFederationDialog(
  BuildContext context, {
  required FederationSelector fed,
  required VoidCallback onLeaveFederation,
}) async {
  final screenNavigator = Navigator.of(context);
  final bitcoinDisplay = context.read<PreferencesProvider>().bitcoinDisplay;

  // Fetch the balance up front so we can warn the user before they leave a
  // federation that still holds funds. Failures here are non-fatal — we just
  // fall back to the plain confirmation dialog.
  BigInt? balanceMsats;
  try {
    balanceMsats = await balance(federationId: fed.federationId);
  } catch (e) {
    AppLogger.instance.warn(
      "Could not fetch balance for leave confirmation: $e",
    );
  }
  if (!context.mounted) return;

  await showDialog(
    context: context,
    builder: (dialogContext) {
      bool isLeaving = false;

      return StatefulBuilder(
        builder: (sbContext, setState) {
          final theme = Theme.of(sbContext);
          final hasBalance = balanceMsats != null && balanceMsats > BigInt.zero;

          return AlertDialog(
            // Keep the dialog from stretching across wide screens (tablet,
            // desktop, foldable) — a modal that spans the viewport reads as
            // a full-screen takeover rather than a focused confirmation.
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 40,
              vertical: 24,
            ),
            title: Row(
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(sbContext.l10n.leaveFederation)),
              ],
            ),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(sbContext.l10n.leaveFederationConfirm),
                  if (hasBalance) ...[
                    const SizedBox(height: 20),
                    // Compact "balance at risk" row — the amount is what
                    // matters, so lead with it. Kept intentionally quiet
                    // (no filled background) so it feels like a fact about
                    // the federation, not a second alarm.
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.account_balance_wallet_outlined,
                          color: theme.colorScheme.onSurfaceVariant,
                          size: 18,
                        ),
                        const SizedBox(width: 10),
                        Text(
                          sbContext.l10n.currentBalance,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          formatBalance(balanceMsats, false, bitcoinDisplay),
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: theme.colorScheme.error,
                            fontWeight: FontWeight.w600,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed:
                    isLeaving ? null : () => Navigator.of(dialogContext).pop(),
                child: Text(sbContext.l10n.cancel),
              ),
              TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: theme.colorScheme.error,
                ),
                onPressed:
                    isLeaving
                        ? null
                        : () async {
                          setState(() {
                            isLeaving = true;
                          });

                          try {
                            await leaveFederation(
                              federationId: fed.federationId,
                            );
                            await stopNwcServiceForFederation(fed.federationId);
                            try {
                              backupInviteCodes();
                            } catch (e) {
                              AppLogger.instance.error(
                                "Could not backup Nostr invite codes: $e",
                              );
                            }
                            onLeaveFederation();

                            if (dialogContext.mounted) {
                              Navigator.of(dialogContext).pop();
                            }
                            screenNavigator.popUntil((route) => route.isFirst);
                          } catch (e) {
                            AppLogger.instance.error(
                              "Error leaving federation: $e",
                            );
                            ToastService().show(
                              message: sbContext.l10n.leaveFederationError,
                              duration: const Duration(seconds: 5),
                              onTap: () {},
                              icon: const Icon(Icons.error),
                            );
                            if (dialogContext.mounted) {
                              Navigator.of(dialogContext).pop();
                            }
                          } finally {
                            if (sbContext.mounted) {
                              setState(() {
                                isLeaving = false;
                              });
                            }
                          }
                        },
                child:
                    isLeaving
                        ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                        : Text(sbContext.l10n.leaveFederation),
              ),
            ],
          );
        },
      );
    },
  );
}
