import 'package:ecashapp/app_error.dart';
import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/toast.dart';
import 'package:ecashapp/utils.dart';
import 'package:flutter/material.dart';

/// Map an [EcashAppError] (or any thrown object that pattern-matches one of
/// its variants) to a localized, user-facing string.
///
/// Unknown errors fall through to the existing generic [context.l10n.failedToSendPayment]
/// so we never surface a stack trace to the user.
String ecashAppErrorToL10n(BuildContext context, Object err) {
  if (err is EcashAppError_ExpiredInvoice) {
    return context.l10n.errExpiredInvoice;
  }
  if (err is EcashAppError_InsufficientBalance) {
    return context.l10n.errInsufficientBalance(
      err.neededMsats.toInt(),
      err.haveMsats.toInt(),
    );
  }
  if (err is EcashAppError_NoRouteFound) return context.l10n.errNoRouteFound;
  if (err is EcashAppError_GatewayOffline) {
    return context.l10n.errGatewayOffline;
  }
  if (err is EcashAppError_NoGatewaysAvailable) {
    return context.l10n.errNoGateways;
  }
  if (err is EcashAppError_FederationOffline) {
    return context.l10n.errFederationOffline;
  }
  if (err is EcashAppError_InvalidInvoice) {
    return context.l10n.errInvalidInvoice(err.field0);
  }
  if (err is EcashAppError_InvalidEcash) {
    return context.l10n.errInvalidEcash(err.field0);
  }
  if (err is EcashAppError_EcashAlreadySpent) {
    return context.l10n.errEcashAlreadySpent;
  }
  if (err is EcashAppError_InvalidBitcoinAddress) {
    return context.l10n.errInvalidBitcoinAddress(err.field0);
  }
  if (err is EcashAppError_InvalidLightningAddress) {
    return context.l10n.errInvalidLightningAddress(err.field0);
  }
  if (err is EcashAppError_PaymentRefunded) {
    return context.l10n.errPaymentRefunded;
  }
  if (err is EcashAppError_Timeout) return context.l10n.errTimeout;
  if (err is EcashAppError_Other) return err.field0;
  return context.l10n.failedToSendPayment;
}

/// Localized message for a *recognized* [EcashAppError] variant, or `null` when
/// the error is generic ([EcashAppError_Other]) or not an [EcashAppError] at all.
///
/// Lets callers (e.g. [showAppModalBottomSheet]) prefer a specific message but
/// fall back to their own context-appropriate text for unknown failures.
String? localizedKnownError(BuildContext context, Object err) {
  if (err is! EcashAppError) return null;
  if (err is EcashAppError_Other) return null;
  return ecashAppErrorToL10n(context, err);
}

/// Show an error toast for an [EcashAppError] (or fallback exception).
void showErrorToast(BuildContext context, Object err) {
  final message = ecashAppErrorToL10n(context, err);
  // Always log when we surface an error toast so the underlying cause is
  // captured in the app log even though the user only sees the localized text.
  AppLogger.instance.error("Showing error toast: $message (raw: $err)");
  ToastService().show(
    message: message,
    duration: const Duration(seconds: 5),
    onTap: () {},
    icon: const Icon(Icons.error, color: Colors.red),
  );
}
