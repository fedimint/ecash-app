import 'package:ecashapp/app_error.dart';
import 'package:ecashapp/extensions/build_context_l10n.dart';
import 'package:ecashapp/toast.dart';
import 'package:flutter/material.dart';

/// Map an [EcashAppError] (or any thrown object that pattern-matches one of
/// its variants) to a localized, user-facing string.
///
/// Unknown errors fall through to the existing generic [context.l10n.failedToSendPayment]
/// so we never surface a stack trace to the user.
String ecashAppErrorToL10n(BuildContext context, Object err) {
  if (err is EcashAppError_ExpiredInvoice) return context.l10n.errExpiredInvoice;
  if (err is EcashAppError_InsufficientBalance) {
    return context.l10n.errInsufficientBalance(
      err.neededMsats.toInt(),
      err.haveMsats.toInt(),
    );
  }
  if (err is EcashAppError_NoRouteFound) return context.l10n.errNoRouteFound;
  if (err is EcashAppError_GatewayOffline) return context.l10n.errGatewayOffline;
  if (err is EcashAppError_NoGatewaysAvailable) return context.l10n.errNoGateways;
  if (err is EcashAppError_FederationOffline) return context.l10n.errFederationOffline;
  if (err is EcashAppError_InvalidInvoice) {
    return context.l10n.errInvalidInvoice(err.field0);
  }
  if (err is EcashAppError_InvalidAddress) {
    return context.l10n.errInvalidAddress(err.field0);
  }
  if (err is EcashAppError_PaymentRefunded) return context.l10n.errPaymentRefunded;
  if (err is EcashAppError_Timeout) return context.l10n.errTimeout;
  if (err is EcashAppError_Other) return err.field0;
  return context.l10n.failedToSendPayment;
}

/// Show an error toast for an [EcashAppError] (or fallback exception).
void showErrorToast(BuildContext context, Object err) {
  ToastService().show(
    message: ecashAppErrorToL10n(context, err),
    duration: const Duration(seconds: 5),
    onTap: () {},
    icon: const Icon(Icons.error, color: Colors.red),
  );
}
