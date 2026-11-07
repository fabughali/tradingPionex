import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:trading_pionex/core/core_storage.dart';
import 'package:trading_pionex/core/gui_instance_lock.dart';

void main() {
  test('first acquire owns the lock and records this PID', () {
    final dir = Directory.systemTemp.createTempSync('tpx_lock_test');
    final storage = CoreStorage.forRoot(dir.path);
    expect(GuiInstanceLock.acquire(storage), isTrue);
    expect(storage.readString(storage.guiPidFile)?.trim(), '$pid');
  });

  // Windows byte-range locks are per file HANDLE, so a second handle in this
  // same process is refused exactly like a second GUI process would be.
  // (POSIX fcntl locks are per process - a same-process re-lock succeeds on
  // Linux, so this case can only be exercised on Windows.)
  test(
    'a second acquire against the same data dir is refused while the first is held',
    () {
      final dir = Directory.systemTemp.createTempSync('tpx_lock_test2');
      final storage = CoreStorage.forRoot(dir.path);
      expect(GuiInstanceLock.acquire(storage), isTrue);
      expect(GuiInstanceLock.acquire(storage), isFalse);
    },
    skip: !Platform.isWindows,
  );
}
