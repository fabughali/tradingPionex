import '../../core/core_storage.dart';

/// The initial investment (USDT) the user has chosen, per pair, via the
/// text field next to each Next Trade row (Dashboard/Controls) and the
/// Controls Check card (per the user, 2026-09-09) - consulted only when a
/// pair's very FIRST real open happens (never overrides an already-running
/// bot's recycled P&L-adjusted amount, which stays exactly as it works
/// today). Defaults to $10 (the pre-existing hardcoded amount) for any pair
/// the user has never touched the field for. No floor is enforced here -
/// per the user, any positive amount is allowed; Pionex's own grid-sizing
/// probe is what actually decides whether a too-small amount can open at
/// all, exactly like every other funding shortfall already does.
class PairInvestmentStore {
  PairInvestmentStore(this._storage) {
    load();
  }

  static const double defaultInvestment = 10.0;

  final CoreStorage _storage;
  final Map<String, double> _bySymbol = {};

  Map<String, double> load() {
    final raw =
        _storage.readJsonObject(_storage.pairInvestmentsFile) ?? const {};
    _bySymbol.clear();
    raw.forEach((symbol, value) {
      final amount = (value as num?)?.toDouble();
      if (amount != null && amount > 0) {
        _bySymbol[symbol.toUpperCase()] = amount;
      }
    });
    return _bySymbol;
  }

  /// Reloads from disk on every call - same cross-process staleness reason
  /// as [PairCategoryStore.categoryOf]: written by the GUI, read by the
  /// long-lived engine process.
  double investmentOf(String symbol) {
    load();
    return _bySymbol[symbol.toUpperCase()] ?? defaultInvestment;
  }

  void setInvestment(String symbol, double amount) {
    if (amount <= 0) return;
    _bySymbol[symbol.toUpperCase()] = amount;
    _storage.writeJson(_storage.pairInvestmentsFile, _bySymbol);
  }

  /// Back to the $10 default - removes the override entirely rather than
  /// writing 10 explicitly, so a future change to the default (unlikely,
  /// but matches [PairCategoryStore]'s own tidiness) doesn't strand stale
  /// explicit values.
  void clearInvestment(String symbol) {
    if (_bySymbol.remove(symbol.toUpperCase()) != null) {
      _storage.writeJson(_storage.pairInvestmentsFile, _bySymbol);
    }
  }
}
