/// Constants for transaction detail keys used across the app
/// This ensures consistency and prevents key mismatch bugs
class TransactionDetailKeys {
  // Prevent instantiation
  TransactionDetailKeys._();

  static const String amount = 'Amount';
  static const String fees = 'Fees';
  static const String ecash = 'E-Cash';
  static const String timestamp = 'Timestamp';
  static const String txid = 'Txid';
  static const String address = 'Address';
  static const String gateway = 'Gateway';
  static const String payeePublicKey = 'Payee Public Key';
  static const String paymentHash = 'Payment Hash';
  static const String preimage = 'Preimage';
  static const String minFeeRate = 'Min Fee Rate';
  static const String maxTxSize = 'Max Tx Size';
  static const String fee = 'Fee';
  static const String total = 'Total';
}
