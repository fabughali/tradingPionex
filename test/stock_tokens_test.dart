import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:trading_pionex/core/core_storage.dart';
import 'package:trading_pionex/data/pionex/pionex_market.dart';

void main() {
  test('first run writes the built-in list; edits are respected', () {
    final dir = Directory.systemTemp.createTempSync('tpx_stock_test');
    final storage = CoreStorage.forRoot(dir.path);
    final first = loadStockTokenBases(storage);
    expect(first, containsAll(['AAPLX', 'SNDKX', 'TSLAX']));
    expect(first.length, defaultStockTokenBases.length);
    expect(File(storage.stockTokensFile).existsSync(), isTrue);

    storage.writeJson(storage.stockTokensFile, ['newx', ' AAPLX ']);
    expect(loadStockTokenBases(storage), {'NEWX', 'AAPLX'});

    File(storage.stockTokensFile).writeAsStringSync('{broken');
    expect(loadStockTokenBases(storage).length, defaultStockTokenBases.length);
    dir.deleteSync(recursive: true);
  });
}
