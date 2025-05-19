extension MilliSats on BigInt {
  BigInt get toSats => this ~/ BigInt.from(1000);
}
