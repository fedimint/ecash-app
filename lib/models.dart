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
