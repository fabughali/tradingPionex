import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trading_pionex/data/providers/app_providers.dart';

void main() {
  test('Selected list keeps ticks across searches, no duplicates, clears on Start', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(selectedPairsProvider.notifier);
    notifier.set('ETHUSDT', true); // first search: eth
    notifier.set('SOLUSDT', true); // second search: sol
    notifier.set('ETHUSDT', true); // ticked again - still once
    expect(container.read(selectedPairsProvider), ['ETHUSDT', 'SOLUSDT']);
    notifier.set('ETHUSDT', false);
    expect(container.read(selectedPairsProvider), ['SOLUSDT']);
    notifier.clear();
    expect(container.read(selectedPairsProvider), isEmpty);
  });
}
