import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/core_constants.dart';
import '../../core/core_layout.dart';
import '../../core/core_spacing.dart';
import '../../core/core_theme.dart';
import '../../data/providers/app_providers.dart';
import '../../l10n/app_localizations.dart';
import '../../widgets/masked_secret_field.dart';
import '../../widgets/reuse_button.dart';
import '../../widgets/reuse_card.dart';

/// Fires the exact same voice+notification pair a real trade trigger would
/// (2026-09-17, per the user - the test buttons should demonstrate the
/// whole feature, not just the voice half). Mirrors `_speak` in
/// `ReuseNavShell` deliberately, including the timestamp on the
/// notification.
void _testAlert(WidgetRef ref, String text) {
  final sound = ref.read(soundServiceProvider);
  sound.speak(text);
  final now = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  final stamp = '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
  sound.notify('$text — $stamp');
}

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late final TextEditingController _tvHost;
  late final TextEditingController _tvPort;
  late final TextEditingController _pionexKey;
  late final TextEditingController _pionexSecret;

  /// Which action is currently in flight, if any — only that action's button
  /// shows a spinner; every button is disabled while any action is running.
  String? _activeAction;
  bool get _busy => _activeAction != null;
  String? _tvTestMessage;
  bool? _tvTestOk;
  String? _pionexTestMessage;
  bool? _pionexTestOk;

  /// Live TradingView Desktop status backing the power toggle — null until
  /// the first background check completes. Re-checked on a loop (paused
  /// while an action is in flight) so the toggle reflects reality even if
  /// TradingView was opened/closed outside this screen (e.g. by the engine).
  bool? _tvUp;
  bool _tvWatching = true;

  @override
  void initState() {
    super.initState();
    final integrations = ref.read(integrationsRepositoryProvider);
    final cdp = integrations.readCdpConfig();
    final pionex = integrations.readPionexCredentials();
    _tvHost = TextEditingController(text: cdp.host);
    _tvPort = TextEditingController(text: cdp.port.toString());
    _pionexKey = TextEditingController(text: pionex.apiKey);
    _pionexSecret = TextEditingController(text: pionex.apiSecret);
    _watchTvStatus();
  }

  Future<void> _watchTvStatus() async {
    final integrations = ref.read(integrationsRepositoryProvider);
    while (_tvWatching) {
      if (!_busy) {
        final port = int.tryParse(_tvPort.text.trim()) ?? 9222;
        final up = await integrations.isTradingViewUp(
          host: _tvHost.text.trim(),
          port: port,
        );
        if (!mounted) return;
        setState(() => _tvUp = up);
      }
      await Future<void>.delayed(const Duration(seconds: 5));
    }
  }

  @override
  void dispose() {
    _tvWatching = false;
    _tvHost.dispose();
    _tvPort.dispose();
    _pionexKey.dispose();
    _pionexSecret.dispose();
    super.dispose();
  }

  Future<void> _run(
    String actionId,
    Future<void> Function() action, {
    String? successMessage,
  }) async {
    setState(() => _activeAction = actionId);
    try {
      await action();
      if (successMessage != null) _notify(successMessage, success: true);
    } catch (e) {
      ref.read(controlRepositoryProvider).logUiOutcome('$e', success: false);
      _notify('$e', success: false);
    } finally {
      if (mounted) setState(() => _activeAction = null);
    }
  }

  void _notify(String message, {required bool success}) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: success ? null : Theme.of(context).colorScheme.error,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final themeMode = ref.watch(themeModeProvider);
    final storage = ref.watch(storageProvider);
    final config = ref.watch(configProvider);
    final integrations = ref.watch(integrationsRepositoryProvider);
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsTitle)),
      body: LayoutBuilder(
        builder: (context, constraints) => ListView(
          padding: CoreLayout.edgeMargin(constraints),
          children: [
            ReuseCard(
              title: l10n.settingsTheme,
              child: SegmentedButton<AppThemeMode>(
                segments: [
                  ButtonSegment(
                    value: AppThemeMode.system,
                    label: Text(l10n.settingsThemeSystem),
                    icon: const Icon(Icons.brightness_auto),
                  ),
                  ButtonSegment(
                    value: AppThemeMode.light,
                    label: Text(l10n.settingsThemeLight),
                    icon: const Icon(Icons.light_mode),
                  ),
                  ButtonSegment(
                    value: AppThemeMode.dark,
                    label: Text(l10n.settingsThemeDark),
                    icon: const Icon(Icons.dark_mode),
                  ),
                ],
                selected: {themeMode},
                onSelectionChanged: (s) =>
                    ref.read(themeModeProvider.notifier).setMode(s.first),
              ),
            ),
            ReuseCard(
              title: 'Remote session',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'This is NOT auto-detected - the machine\'s own session '
                    'info has proven unreliable for this. Tell the app '
                    'which kind of session you\'re on right now.',
                    style: textTheme.bodySmall,
                  ),
                  const SizedBox(height: CoreSpacing.sm),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Remote session'),
                    subtitle: Text(
                      config.remoteSession
                          ? 'TradingView stays hidden on an isolated display - safe for remote access.'
                          : 'TradingView shows normally - only safe on a genuinely local/direct session.',
                    ),
                    value: config.remoteSession,
                    onChanged: (v) {
                      integrations.saveRemoteSession(v);
                      ref.invalidate(configProvider);
                    },
                  ),
                ],
              ),
            ),
            ReuseCard(
              title: 'Voice alerts',
              child: Builder(
                builder: (context) {
                  final muted = ref.watch(soundMuteProvider);
                  final notifier = ref.read(soundMuteProvider.notifier);
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Start alerts'),
                        subtitle: const Text(
                          'Speaks "start long/short PAIR" and shows a system notification whenever a real trade opens.',
                        ),
                        value: muted['start'] != true,
                        onChanged: (v) => notifier.setMuted('start', !v),
                        secondary: IconButton(
                          tooltip: 'Test - plays/shows regardless of the mute toggle above',
                          icon: const Icon(Icons.volume_up_outlined),
                          onPressed: () => _testAlert(ref, 'start long XRP'),
                        ),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Stop alerts'),
                        subtitle: const Text(
                          'Speaks "close PAIR" and shows a system notification whenever a trade closes.',
                        ),
                        value: muted['stop'] != true,
                        onChanged: (v) => notifier.setMuted('stop', !v),
                        secondary: IconButton(
                          tooltip: 'Test - plays/shows regardless of the mute toggle above',
                          icon: const Icon(Icons.volume_up_outlined),
                          onPressed: () => _testAlert(ref, 'close XRP'),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            ReuseCard(
              title: l10n.settingsTitle,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SettingRow(
                    label: l10n.settingsPollInterval,
                    value: '${config.pollIntervalSec}s',
                  ),
                  // "Grid pairs" removed (2026-09-06, per the user) - this
                  // was config.json's grid_pairs, a dead fallback default
                  // only ever used if the Red List itself is completely
                  // unreadable (see _runCycle's pairUniverse). Showing
                  // "BINANCE:BTCUSDT" here was misleading, implying the
                  // app is restricted to Binance - it isn't, and this
                  // value plays no real role in normal operation.
                  _SettingRow(
                    label: l10n.settingsDataDirectory,
                    value: storage.rootDir,
                  ),
                  const SizedBox(height: CoreSpacing.sm),
                  Text(
                    'Edit config.json in the data directory above and restart the engine to change these.',
                    style: textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(
                top: CoreSpacing.sm,
                bottom: CoreSpacing.sm,
              ),
              child: Text(
                l10n.settingsIntegrations,
                style: textTheme.titleMedium,
              ),
            ),
            ReuseCard(
              title: l10n.integrationTradingView,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _tvHost,
                          decoration: InputDecoration(
                            labelText: l10n.fieldHost,
                          ),
                        ),
                      ),
                      const SizedBox(width: CoreSpacing.sm),
                      SizedBox(
                        width: 100,
                        child: TextField(
                          controller: _tvPort,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: l10n.fieldPort,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: CoreSpacing.sm),
                  Row(
                    children: [
                      if (_activeAction == 'tv-power')
                        const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else
                        Switch(
                          value: _tvUp ?? false,
                          onChanged: _busy || _tvUp == null
                              ? null
                              : (v) => _run('tv-power', () async {
                                  final port =
                                      int.tryParse(_tvPort.text.trim()) ??
                                      9222;
                                  final host = _tvHost.text.trim();
                                  final result = v
                                      ? await integrations.testTradingView(
                                          host: host,
                                          port: port,
                                        )
                                      : await integrations.powerOffTradingView(
                                          host: host,
                                          port: port,
                                        );
                                  final nowUp = await integrations
                                      .isTradingViewUp(host: host, port: port);
                                  if (!mounted) return;
                                  setState(() {
                                    _tvUp = nowUp;
                                    _tvTestOk = result.ok;
                                    _tvTestMessage = result.message;
                                  });
                                  ref
                                      .read(controlRepositoryProvider)
                                      .logUiOutcome(
                                        'TradingView ${v ? 'power on' : 'power off'}: ${result.message}',
                                        success: result.ok,
                                      );
                                  _notify(result.message, success: result.ok);
                                }),
                        ),
                      const SizedBox(width: CoreSpacing.sm),
                      Text(
                        _tvUp == null
                            ? 'Checking…'
                            : (_tvUp!
                                  ? 'TradingView Desktop is running'
                                  : 'TradingView Desktop is stopped'),
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                  ),
                  const SizedBox(height: CoreSpacing.sm),
                  if (_tvTestMessage != null)
                    _TestResultBanner(ok: _tvTestOk!, message: _tvTestMessage!),
                  const SizedBox(height: CoreSpacing.sm),
                  Wrap(
                    spacing: CoreSpacing.sm,
                    children: [
                      ReuseButton(
                        label: l10n.actionTestConnection,
                        icon: Icons.wifi_tethering,
                        tone: ReuseButtonTone.neutral,
                        loading: _activeAction == 'tv-test',
                        onPressed: _busy
                            ? null
                            : () => _run('tv-test', () async {
                                final port =
                                    int.tryParse(_tvPort.text.trim()) ?? 9222;
                                final result = await integrations
                                    .testTradingView(
                                      host: _tvHost.text.trim(),
                                      port: port,
                                    );
                                setState(() {
                                  _tvTestOk = result.ok;
                                  _tvTestMessage = result.message;
                                });
                                ref
                                    .read(controlRepositoryProvider)
                                    .logUiOutcome(
                                      'TradingView connection test: ${result.message}',
                                      success: result.ok,
                                    );
                                _notify(result.message, success: result.ok);
                              }),
                      ),
                      ReuseButton(
                        label: l10n.actionSave,
                        icon: Icons.save_outlined,
                        loading: _activeAction == 'tv-save',
                        onPressed: _busy
                            ? null
                            : () => _run(
                                'tv-save',
                                () async {
                                  final port =
                                      int.tryParse(_tvPort.text.trim()) ?? 9222;
                                  integrations.saveCdpConfig(
                                    host: _tvHost.text.trim(),
                                    port: port,
                                  );
                                  ref.invalidate(configProvider);
                                },
                                successMessage:
                                    'Saved — restart the engine to pick this up.',
                              ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            ReuseCard(
              title: l10n.integrationPionex,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  MaskedSecretField(
                    controller: _pionexKey,
                    label: l10n.fieldApiKey,
                  ),
                  const SizedBox(height: CoreSpacing.sm),
                  MaskedSecretField(
                    controller: _pionexSecret,
                    label: l10n.fieldApiSecret,
                  ),
                  const SizedBox(height: CoreSpacing.sm),
                  if (_pionexTestMessage != null)
                    _TestResultBanner(
                      ok: _pionexTestOk!,
                      message: _pionexTestMessage!,
                    ),
                  const SizedBox(height: CoreSpacing.sm),
                  Wrap(
                    spacing: CoreSpacing.sm,
                    children: [
                      ReuseButton(
                        label: l10n.actionTestConnection,
                        icon: Icons.wifi_tethering,
                        tone: ReuseButtonTone.neutral,
                        loading: _activeAction == 'pionex-test',
                        onPressed: _busy
                            ? null
                            : () => _run('pionex-test', () async {
                                final result = await integrations.testPionex(
                                  apiKey: _pionexKey.text.trim(),
                                  apiSecret: _pionexSecret.text.trim(),
                                );
                                setState(() {
                                  _pionexTestOk = result.ok;
                                  _pionexTestMessage = result.message;
                                });
                                ref
                                    .read(controlRepositoryProvider)
                                    .logUiOutcome(
                                      'Pionex connection test: ${result.message}',
                                      success: result.ok,
                                    );
                                _notify(result.message, success: result.ok);
                              }),
                      ),
                      ReuseButton(
                        label: l10n.actionSave,
                        icon: Icons.save_outlined,
                        loading: _activeAction == 'pionex-save',
                        onPressed: _busy
                            ? null
                            : () => _run(
                                'pionex-save',
                                () async {
                                  integrations.savePionexCredentials(
                                    apiKey: _pionexKey.text.trim(),
                                    apiSecret: _pionexSecret.text.trim(),
                                  );
                                  ref.invalidate(pionexClientProvider);
                                  ref.invalidate(statusReportProvider);
                                },
                                successMessage:
                                    'Saved to .env — restart the engine to pick this up.',
                              ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            ReuseCard(
              title: l10n.settingsAbout,
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Version ${CoreConstants.appVersion}',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'TradingPionex — a deterministic crypto futures-grid trading engine.',
                  ),
                  SizedBox(height: 4),
                  Text(
                    'The engine (bin/engine.dart) is the sole trading-decision authority. This app is the dashboard/operator surface only.',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TestResultBanner extends StatelessWidget {
  const _TestResultBanner({required this.ok, required this.message});

  final bool ok;
  final String message;

  @override
  Widget build(BuildContext context) {
    final trading = context.tradingColors;
    final color = ok ? trading.profit : trading.loss;
    return Container(
      padding: const EdgeInsets.all(CoreSpacing.sm),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            ok ? Icons.check_circle_outline : Icons.error_outline,
            color: color,
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message, style: TextStyle(color: color)),
          ),
        ],
      ),
    );
  }
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 140,
            child: Text(label, style: Theme.of(context).textTheme.labelLarge),
          ),
          Expanded(
            child: Text(value, style: Theme.of(context).textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}
