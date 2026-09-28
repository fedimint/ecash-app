import 'package:ecashapp/generated/app_localizations.dart';
import 'package:ecashapp/multimint.dart';

/// Defines the available payment methods in the app
enum PaymentType { lightning, onchain, ecash }

extension PaymentTypeRecovery on PaymentType {
  /// The recovery bar this payment type reads.
  ///
  /// Deliberately not a module instance id: guardians assign those by
  /// enumerating the federation's *enabled* modules alphabetically by kind, so
  /// the same payment type sits at a different id on a v2-only federation than
  /// on a legacy one. Rust resolves the ids from the client config and
  /// aggregates across the modules behind one bar.
  RecoveryModule get recoveryModule => switch (this) {
    PaymentType.lightning => RecoveryModule.lightning,
    PaymentType.onchain => RecoveryModule.onchain,
    PaymentType.ecash => RecoveryModule.ecash,
  };
}

extension RecoveryModuleLabel on RecoveryModule {
  /// The payment-type name shown to the user for this recovery group.
  ///
  /// Reuses the payment-type strings the rest of the UI already uses, so a
  /// recovery row names its module the same way the tab that contains it does.
  String label(AppLocalizations l10n) => switch (this) {
    RecoveryModule.lightning => l10n.lightning,
    RecoveryModule.onchain => l10n.onchain,
    RecoveryModule.ecash => l10n.ecash,
  };
}
