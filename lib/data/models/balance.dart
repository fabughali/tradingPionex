class Balance {
  const Balance({required this.free, required this.total});

  final double free;
  final double total;

  static const zero = Balance(free: 0, total: 0);

  bool canTrade(double minFree) => free >= minFree;
}
