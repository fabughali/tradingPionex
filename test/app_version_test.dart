import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:trading_pionex/core/core_constants.dart';

void main() {
  test('app version shown in the app equals pubspec.yaml version', () {
    final line = File('pubspec.yaml')
        .readAsLinesSync()
        .firstWhere((l) => l.startsWith('version:'));
    expect(CoreConstants.appVersion, line.substring('version:'.length).trim());
  });
}
