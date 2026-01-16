import 'package:ecashapp/models.dart';

/// Validates if an amount is valid for the given payment context.
///
/// For lightning receives (no address/lnurl), only checks amount > 0.
/// For sends (lightning with address, ecash, onchain), also checks balance.
///
/// Returns true if the amount is valid.
bool isValidAmount({
  required String rawAmount,
  required bool loadingBalance,
  required BigInt? currentBalance,
  required PaymentType paymentType,
  required bool isLightningReceive,
}) {
  if (loadingBalance) return false;

  final amountSats = BigInt.tryParse(rawAmount);
  if (amountSats == null || amountSats == BigInt.zero) {
    return false;
  }

  if (isLightningReceive) {
    return true;
  }

  if (currentBalance != null) {
    final amountMsats = amountSats * BigInt.from(1000);
    return amountMsats <= currentBalance;
  }

  return true;
}

/// Checks if the entered amount exceeds the available balance.
///
/// Returns false during loading or when balance is unavailable.
/// Returns false for lightning receives (balance check doesn't apply).
bool isAmountOverBalance({
  required String rawAmount,
  required bool loadingBalance,
  required BigInt? currentBalance,
  required bool isLightningReceive,
}) {
  if (loadingBalance || currentBalance == null) return false;

  final amountSats = BigInt.tryParse(rawAmount);
  if (amountSats == null || amountSats == BigInt.zero) {
    return false;
  }

  if (isLightningReceive) {
    return false;
  }

  final amountMsats = amountSats * BigInt.from(1000);
  return amountMsats > currentBalance;
}

/// Calculates the remaining balance after subtracting the entered amount.
///
/// Returns null if balance is loading or unavailable.
/// Returns the full balance if no amount is entered.
/// Clamps to zero if amount exceeds balance.
BigInt? getRemainingBalance({
  required String rawAmount,
  required bool loadingBalance,
  required BigInt? currentBalance,
}) {
  if (loadingBalance || currentBalance == null) return null;

  final amountSats = BigInt.tryParse(rawAmount);
  if (amountSats == null) {
    return currentBalance;
  }

  final amountMsats = amountSats * BigInt.from(1000);
  final remaining = currentBalance - amountMsats;

  return remaining < BigInt.zero ? BigInt.zero : remaining;
}

/// Returns true if we can add another digit in fiat mode.
/// Limits to 2 decimal places for fiat currencies.
bool canAddFiatDigit(String? displayedFiatInput) {
  if (displayedFiatInput == null) return true;
  if (!displayedFiatInput.contains('.')) return true;
  final parts = displayedFiatInput.split('.');
  return parts.length < 2 || parts[1].length < 2;
}
