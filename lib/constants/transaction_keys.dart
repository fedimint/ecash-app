/// Constants for transaction detail keys used across the app
/// This ensures consistency and prevents key mismatch bugs
class TransactionDetailKeys {
  // Prevent instantiation
  TransactionDetailKeys._();

  static const String amount = 'Amount';
  static const String totalAmount = 'Total Amount';
  static const String receivedAmount = 'Received Amount';
  static const String fees = 'Fees';
  static const String federationFee = 'Federation Fee';
  static const String onchainClaimFee = 'On-chain Claim Fee';
  static const String gatewayFee = 'Gateway Fee';
  static const String bitcoinNetworkFee = 'Bitcoin Network Fee';
  static const String ecash = 'Ecash';
  static const String timestamp = 'Timestamp';
  static const String txid = 'Txid';
  static const String address = 'Address';
  static const String gateway = 'Gateway';
  static const String payeePublicKey = 'Payee Pubkey';
  static const String paymentHash = 'Payment Hash';
  static const String preimage = 'Preimage';
  static const String lnAddress = 'LN Address';
  static const String lnurl = 'LNURL';
  static const String invoice = 'Invoice';
  static const String minFeeRate = 'Min Fee Rate';
  static const String maxTxSize = 'Max Tx Size';
  static const String fee = 'Fee';
  static const String total = 'Total';
  static const String inputFees = "Input Fees";
  static const String outputFees = "Output Fees";
  static const String dust = "Dust";
}
