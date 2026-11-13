import 'dart:async';
import 'dart:io';

import 'package:tray_manager/tray_manager.dart';

/// The app's icon in the Windows notification area, next to the clock (per
/// the user, 2026-11-14). Tooltip shows the Power state; left-click brings
/// the window to the front; right-click opens a small menu.
class AppTray with TrayListener {
  AppTray({required this.isPowerOn});

  final bool Function() isPowerOn;
  Timer? _timer;
  bool? _shownPower;

  Future<void> start() async {
    if (!Platform.isWindows) return;
    try {
      trayManager.addListener(this);
      await trayManager.setIcon('assets/icons/app_icon.ico');
      await _refresh();
      _timer = Timer.periodic(const Duration(seconds: 10), (_) => _refresh());
    } catch (_) {
      // A missing tray never stops the app.
    }
  }

  Future<void> _refresh() async {
    final on = isPowerOn();
    if (on == _shownPower) return;
    _shownPower = on;
    try {
      await trayManager.setToolTip('TradingPionex - Power ${on ? 'on' : 'off'}');
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: 'open', label: 'Open TradingPionex'),
            MenuItem.separator(),
            MenuItem(label: 'Power: ${on ? 'on' : 'off'}', disabled: true),
          ],
        ),
      );
    } catch (_) {}
  }

  void dispose() {
    _timer?.cancel();
    trayManager.removeListener(this);
  }

  @override
  void onTrayIconMouseDown() => _bringToFront();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (menuItem.key == 'open') _bringToFront();
  }

  /// Same way the app already focuses its own window (GuiInstanceLock).
  Future<void> _bringToFront() async {
    try {
      await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        '(New-Object -ComObject WScript.Shell).AppActivate($pid) | Out-Null',
      ]);
    } catch (_) {}
  }
}
