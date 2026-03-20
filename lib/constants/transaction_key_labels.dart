import 'package:ecashapp/constants/transaction_keys.dart';
import 'package:ecashapp/generated/app_localizations.dart';

/// Returns the localized display label for a TransactionDetailKey string.
/// Falls back to the raw key string if no translation exists.
/// The raw constant values must NOT change as they serve as Map keys at runtime.
String localizedTxLabel(AppLocalizations l10n, String key) {
  return switch (key) {
    TransactionDetailKeys.amount => l10n.txDetailAmount,
    TransactionDetailKeys.fees => l10n.txDetailFees,
    TransactionDetailKeys.ecash => l10n.ecash,
    TransactionDetailKeys.timestamp => l10n.txDetailTimestamp,
    TransactionDetailKeys.txid => l10n.txDetailTxid,
    TransactionDetailKeys.address => l10n.txDetailAddress,
    TransactionDetailKeys.gateway => l10n.txDetailGateway,
    TransactionDetailKeys.payeePublicKey => l10n.txDetailPayeePubkey,
    TransactionDetailKeys.paymentHash => l10n.txDetailPaymentHash,
    TransactionDetailKeys.preimage => l10n.txDetailPreimage,
    TransactionDetailKeys.lnAddress => l10n.txDetailLnAddress,
    TransactionDetailKeys.minFeeRate => l10n.txDetailMinFeeRate,
    TransactionDetailKeys.maxTxSize => l10n.txDetailMaxTxSize,
    TransactionDetailKeys.fee => l10n.txDetailFee,
    TransactionDetailKeys.total => l10n.txDetailTotal,
    TransactionDetailKeys.inputFees => l10n.txDetailInputFees,
    TransactionDetailKeys.outputFees => l10n.txDetailOutputFees,
    TransactionDetailKeys.dust => l10n.txDetailDust,
    _ => key,
  };
}
