// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'TradingPionex';

  @override
  String get navDashboard => 'Dashboard';

  @override
  String get navControls => 'Controls';

  @override
  String get navLogs => 'Logs';

  @override
  String get navSettings => 'Settings';

  @override
  String get dashboardEngineStatus => 'Engine status';

  @override
  String get dashboardBalance => 'Balance';

  @override
  String get dashboardActiveGrids => 'Active grids';

  @override
  String get engineStateRunning => 'Running';

  @override
  String get engineStatePaused => 'Paused';

  @override
  String get engineStateKillSwitched => 'Kill switch';

  @override
  String get engineStateStopped => 'Not running';

  @override
  String lastUpdated(String when) {
    return 'Updated $when';
  }

  @override
  String get engineNeverStarted =>
      'The engine hasn\'t been started yet — run bin/engine.dart.';

  @override
  String get balanceFree => 'Free';

  @override
  String get balanceTotal => 'Total';

  @override
  String get balanceCanTrade => 'Can open new grids';

  @override
  String get balanceCannotTrade => 'Below \$10 minimum';

  @override
  String get controlsTitle => 'Controls';

  @override
  String get controlsForceStop => 'Force stop (pause)';

  @override
  String get controlsResume => 'Resume';

  @override
  String get controlsCheckNow => 'Check now';

  @override
  String get controlsStopAll => 'Stop all auto grids';

  @override
  String get controlsPausedNotice =>
      'The engine is force-stopped — no opens or closes will happen until you resume.';

  @override
  String get controlsStop => 'Stop';

  @override
  String get controlsSelectPairsTitle => 'Restrict next creation to';

  @override
  String get controlsSelectPairsHint => 'Comma-separated bases, e.g. BTC, ETH';

  @override
  String get controlsApply => 'Apply';

  @override
  String get controlsRetiredTitle => 'Retired pairs';

  @override
  String get controlsRetireHint => 'Comma-separated bases to retire';

  @override
  String get controlsUnretireHint => 'Comma-separated bases to unretire';

  @override
  String get logsTitle => 'Logs';

  @override
  String get logsRefresh => 'Refresh';

  @override
  String get logsClear => 'Clear';

  @override
  String get logsEmpty =>
      'No log lines yet — the engine writes here once it\'s running.';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get settingsTheme => 'Theme';

  @override
  String get settingsThemeSystem => 'System';

  @override
  String get settingsThemeLight => 'Light';

  @override
  String get settingsThemeDark => 'Dark';

  @override
  String get settingsDataDirectory => 'Data directory';

  @override
  String get settingsMode => 'Mode';

  @override
  String get settingsPollInterval => 'Poll interval';

  @override
  String get settingsAbout => 'About';

  @override
  String get dashboardPower => 'Power';

  @override
  String get dashboardPowerOn => 'Live';

  @override
  String get dashboardPowerOff => 'Powered down';

  @override
  String get dashboardNextCheckup => 'Next checkup';

  @override
  String get dashboardLastPowerDown => 'Last power-down';

  @override
  String get dashboardNeverPoweredDown => 'Never';

  @override
  String get dashboardQuickActions => 'Quick actions';

  @override
  String get actionStart => 'Start (auto-run)';

  @override
  String get actionCheckNow => 'Check now';

  @override
  String get actionStopAll => 'Stop all';

  @override
  String get actionLast => 'Last all';

  @override
  String get dashboardAutoBots => 'Auto bots (app-initiated)';

  @override
  String get dashboardAvailablePairs => 'Redlist Pairs';

  @override
  String get dashboardNoAvailablePairs =>
      'No eligible pairs right now — every Red-list pair is either retired or already has an auto grid running.';

  @override
  String get dashboardRetireDialogTitle => 'Retire running auto bots';

  @override
  String get dashboardRetireDialogBody =>
      'Selected bots will finish naturally and never auto-recreate.';

  @override
  String get dashboardRetireSelected => 'Retire selected';

  @override
  String get settingsIntegrations => 'Integrations';

  @override
  String get integrationTradingView => 'TradingView Desktop';

  @override
  String get integrationPionex => 'Pionex';

  @override
  String get fieldApiKey => 'API key';

  @override
  String get fieldApiSecret => 'API secret';

  @override
  String get fieldHost => 'Host';

  @override
  String get fieldPort => 'Port';

  @override
  String get actionTestConnection => 'Test connection';

  @override
  String get actionSave => 'Save';

  @override
  String get actionCopy => 'Copy';
}
