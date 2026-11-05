import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:trading_pionex/core/engine_process.dart';

void main() {
  group('tasklistOutputIsEngine', () {
    test('matches the engine image row, in any case', () {
      expect(
        tasklistOutputIsEngine(
          '"trading_pionex_engine.exe","1234","Console","1","50,000 K"\r\n',
        ),
        isTrue,
      );
      expect(
        tasklistOutputIsEngine('"Trading_Pionex_Engine.EXE","1234"'),
        isTrue,
      );
    });

    test('rejects a reused PID held by another process', () {
      expect(
        tasklistOutputIsEngine('"other_engine.exe","1234","Console"'),
        isFalse,
      );
      expect(tasklistOutputIsEngine('"chrome.exe","1234"'), isFalse);
    });

    test('rejects the no-tasks message', () {
      expect(
        tasklistOutputIsEngine(
          'INFO: No tasks are running which match the specified criteria.',
        ),
        isFalse,
      );
    });
  });

  test('isEngineProcess rejects this test process and an unused PID', () {
    expect(isEngineProcess(pid), isFalse);
    expect(isEngineProcess(999999), isFalse);
  });

  test('binary name has the right extension for this platform', () {
    expect(engineBinaryFileName.endsWith('.exe'), Platform.isWindows);
  });
}
