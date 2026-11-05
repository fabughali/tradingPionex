import 'dart:io';

/// The private, isolated X display TradingView Desktop always runs on -
/// never the real session's display. Confirmed live on 2026-09-03: with
/// TradingView opening a window on the same Wayland/XWayland session that
/// serves the user's remote desktop, every single TradingView launch (6/6)
/// crashed Mutter/GNOME Shell with SIGSEGV within seconds, tearing down the
/// ENTIRE remote session (RDP, every open app, including Claude's own
/// desktop client) - confirmed via journalctl showing every crash landing
/// right after a TradingView spawn, and the crash's own teardown cascade
/// disconnecting unrelated clients like claude-desktop. Disabling GPU
/// compositing alone (`--disable-gpu`) reduced but did not eliminate this.
/// Running TradingView on its own Xvfb display instead means a crash there
/// can only ever take down that private display, never the user's actual
/// session - the engine only ever talks to TradingView via the CDP port
/// (127.0.0.1:9222) so nothing about automation depends on which display it
/// renders to.
const String virtualDisplay = ':77';

/// Whether this app may kill and launch TradingView Desktop itself. False on
/// Windows (2026-11-01): the launch path below is Linux-only (Xvfb, pkill, a
/// fixed binary path), and on that machine TradingView is opened by hand and
/// may be shared with other software using the same debug port, so killing
/// it isn't this app's call. Callers report that it needs opening manually.
bool get canControlTradingView => !Platform.isWindows;

/// Starts the private Xvfb display TradingView renders to, if it isn't
/// already up. No-op if it's already running (checked via its socket file,
/// not a PID we'd have to track across engine restarts).
Future<void> ensureVirtualDisplayUp({
  Duration timeout = const Duration(seconds: 10),
}) async {
  final socketFile = File(
    '/tmp/.X11-unix/X${virtualDisplay.replaceFirst(':', '')}',
  );
  if (socketFile.existsSync()) return;

  await Process.start('Xvfb', [
    virtualDisplay,
    '-screen',
    '0',
    '1920x1080x24',
    '-nolisten',
    'tcp',
  ], mode: ProcessStartMode.detached);

  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (socketFile.existsSync()) return;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}

/// Auto-launches TradingView Desktop if CDP is down — ported 1:1 from
/// lib/launch.js. display/xauthority/etc. are deliberately null by default
/// (see [launchTradingView]) rather than hardcoded: a fixed Xauthority path
/// (e.g. GDM's) breaks the moment the session type changes - confirmed live
/// when this machine switched from a local GDM session to remote access,
/// which uses a different, randomly-named Xwayland auth file each time. The
/// engine process's own environment already has the right values for
/// whatever session it's actually running in; only set these explicitly if
/// a specific override is genuinely needed. NOTE: none of this applies to
/// DISPLAY any more - TradingView is always forced onto [virtualDisplay],
/// see that constant's doc comment for why.
class LaunchConfig {
  const LaunchConfig({
    required this.binaryPath,
    this.display,
    this.xauthority,
    this.dbusSessionBusAddress,
    this.xdgRuntimeDir,
  });

  final String binaryPath;
  final String? display;
  final String? xauthority;
  final String? dbusSessionBusAddress;
  final String? xdgRuntimeDir;

  static LaunchConfig defaultForHome(String home) => LaunchConfig(
    binaryPath: '$home/Applications/tradingview/opt/TradingView/tradingview',
  );
}

Future<bool> isCdpUp(String host, int port) async {
  final client = HttpClient();
  try {
    final request = await client
        .getUrl(Uri.parse('http://$host:$port/json/version'))
        .timeout(const Duration(seconds: 8));
    final response = await request.close().timeout(const Duration(seconds: 8));
    return response.statusCode == 200;
  } catch (_) {
    return false;
  } finally {
    client.close(force: true);
  }
}

/// Kills any stale TradingView process and relaunches it with the CDP debug
/// port open. Waits until the port responds, or gives up after [timeout].
Future<bool> launchTradingView(
  String host,
  int port,
  LaunchConfig config, {
  Duration timeout = const Duration(seconds: 30),
  // Manual, user-controlled (AppConfig.remoteSession) - NOT auto-detected.
  // true (the default, matching the config default): isolate TradingView on
  // virtualDisplay, invisible, since opening it on the real display has
  // repeatedly crashed this kind of remote-access session (confirmed live
  // 2026-09-04). false: show it normally on the real display, for a
  // genuinely local/direct session where that risk doesn't apply and the
  // user actually wants to see the chart.
  bool remoteSession = true,
}) async {
  if (!canControlTradingView) return false;
  try {
    await Process.run('pkill', ['-9', '-f', config.binaryPath]);
  } catch (_) {}
  await Future<void>.delayed(const Duration(seconds: 2));

  final home = Platform.environment['HOME'] ?? '';
  final Map<String, String> env;
  if (remoteSession) {
    await ensureVirtualDisplayUp();
    // Inherits XAUTHORITY/DBUS_SESSION_BUS_ADDRESS/XDG_RUNTIME_DIR from the
    // engine's own live environment (harmless - TradingView doesn't need
    // the real session's X auth since it's not touching the real display
    // at all). DISPLAY is forced to the isolated virtualDisplay, never the
    // caller's config or the inherited real one - see virtualDisplay's doc
    // comment for why.
    env = {
      ...Platform.environment,
      if (config.xauthority != null) 'XAUTHORITY': config.xauthority!,
      if (config.dbusSessionBusAddress != null)
        'DBUS_SESSION_BUS_ADDRESS': config.dbusSessionBusAddress!,
      if (config.xdgRuntimeDir != null)
        'XDG_RUNTIME_DIR': config.xdgRuntimeDir!,
      'HOME': home,
      'DISPLAY': virtualDisplay,
    }..remove('WAYLAND_DISPLAY');
  } else {
    // Local/direct session - show it for real. Inherits the engine's own
    // live DISPLAY/WAYLAND_DISPLAY/XAUTHORITY/etc as-is (correct for
    // whatever session it's actually running in), only overridden if a
    // caller explicitly passed a value.
    env = {
      ...Platform.environment,
      if (config.display != null) 'DISPLAY': config.display!,
      if (config.xauthority != null) 'XAUTHORITY': config.xauthority!,
      if (config.dbusSessionBusAddress != null)
        'DBUS_SESSION_BUS_ADDRESS': config.dbusSessionBusAddress!,
      if (config.xdgRuntimeDir != null)
        'XDG_RUNTIME_DIR': config.xdgRuntimeDir!,
      'HOME': home,
    };
  }

  await Process.start(
    config.binaryPath,
    [
      '--remote-debugging-port=$port',
      '--ozone-platform=x11',
      // Only needed for the isolated/invisible path - virtualDisplay
      // isolation is what actually prevents a crash from reaching the
      // user's real session, but there's no reason to burn real GPU
      // compositing on a display nobody ever looks at either. A genuinely
      // local, visible session should render normally.
      if (remoteSession) '--disable-gpu',
    ],
    environment: env,
    mode: ProcessStartMode.detached,
  );

  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await isCdpUp(host, port)) return true;
    await Future<void>.delayed(const Duration(milliseconds: 800));
  }
  return false;
}

/// Kills TradingView Desktop if it's running, and waits until CDP stops
/// responding (or gives up after [timeout]) so the caller knows the process
/// is actually gone before reporting success.
Future<bool> stopTradingView(
  String host,
  int port,
  LaunchConfig config, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  if (!canControlTradingView) return false;
  try {
    await Process.run('pkill', ['-9', '-f', config.binaryPath]);
  } catch (_) {}

  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (!await isCdpUp(host, port)) return true;
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  return false;
}
