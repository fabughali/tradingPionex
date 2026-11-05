import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[Locale('en')];

  /// The application name shown in the OS title bar and app switcher.
  ///
  /// In en, this message translates to:
  /// **'TradingPionex'**
  String get appTitle;

  /// No description provided for @navDashboard.
  ///
  /// In en, this message translates to:
  /// **'Dashboard'**
  String get navDashboard;

  /// No description provided for @navControls.
  ///
  /// In en, this message translates to:
  /// **'Controls'**
  String get navControls;

  /// No description provided for @navLogs.
  ///
  /// In en, this message translates to:
  /// **'Logs'**
  String get navLogs;

  /// No description provided for @navSettings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get navSettings;

  /// No description provided for @dashboardEngineStatus.
  ///
  /// In en, this message translates to:
  /// **'Engine status'**
  String get dashboardEngineStatus;

  /// No description provided for @dashboardBalance.
  ///
  /// In en, this message translates to:
  /// **'Balance'**
  String get dashboardBalance;

  /// No description provided for @dashboardActiveGrids.
  ///
  /// In en, this message translates to:
  /// **'Active grids'**
  String get dashboardActiveGrids;

  /// No description provided for @engineStateRunning.
  ///
  /// In en, this message translates to:
  /// **'Running'**
  String get engineStateRunning;

  /// No description provided for @engineStatePaused.
  ///
  /// In en, this message translates to:
  /// **'Paused'**
  String get engineStatePaused;

  /// No description provided for @engineStateKillSwitched.
  ///
  /// In en, this message translates to:
  /// **'Kill switch'**
  String get engineStateKillSwitched;

  /// No description provided for @engineStateStopped.
  ///
  /// In en, this message translates to:
  /// **'Not running'**
  String get engineStateStopped;

  /// No description provided for @lastUpdated.
  ///
  /// In en, this message translates to:
  /// **'Updated {when}'**
  String lastUpdated(String when);

  /// No description provided for @engineNeverStarted.
  ///
  /// In en, this message translates to:
  /// **'The engine hasn\'t been started yet — run bin/engine.dart.'**
  String get engineNeverStarted;

  /// No description provided for @balanceFree.
  ///
  /// In en, this message translates to:
  /// **'Free'**
  String get balanceFree;

  /// No description provided for @balanceTotal.
  ///
  /// In en, this message translates to:
  /// **'Total'**
  String get balanceTotal;

  /// No description provided for @balanceCanTrade.
  ///
  /// In en, this message translates to:
  /// **'Can open new grids'**
  String get balanceCanTrade;

  /// No description provided for @balanceCannotTrade.
  ///
  /// In en, this message translates to:
  /// **'Below \$10 minimum'**
  String get balanceCannotTrade;

  /// No description provided for @controlsTitle.
  ///
  /// In en, this message translates to:
  /// **'Controls'**
  String get controlsTitle;

  /// No description provided for @controlsForceStop.
  ///
  /// In en, this message translates to:
  /// **'Force stop (pause)'**
  String get controlsForceStop;

  /// No description provided for @controlsResume.
  ///
  /// In en, this message translates to:
  /// **'Resume'**
  String get controlsResume;

  /// No description provided for @controlsCheckNow.
  ///
  /// In en, this message translates to:
  /// **'Check now'**
  String get controlsCheckNow;

  /// No description provided for @controlsStopAll.
  ///
  /// In en, this message translates to:
  /// **'Stop all auto grids'**
  String get controlsStopAll;

  /// No description provided for @controlsPausedNotice.
  ///
  /// In en, this message translates to:
  /// **'The engine is force-stopped — no opens or closes will happen until you resume.'**
  String get controlsPausedNotice;

  /// No description provided for @controlsStop.
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get controlsStop;

  /// No description provided for @controlsSelectPairsTitle.
  ///
  /// In en, this message translates to:
  /// **'Restrict next creation to'**
  String get controlsSelectPairsTitle;

  /// No description provided for @controlsSelectPairsHint.
  ///
  /// In en, this message translates to:
  /// **'Comma-separated bases, e.g. BTC, ETH'**
  String get controlsSelectPairsHint;

  /// No description provided for @controlsApply.
  ///
  /// In en, this message translates to:
  /// **'Apply'**
  String get controlsApply;

  /// No description provided for @controlsRetiredTitle.
  ///
  /// In en, this message translates to:
  /// **'Retired pairs'**
  String get controlsRetiredTitle;

  /// No description provided for @controlsRetireHint.
  ///
  /// In en, this message translates to:
  /// **'Comma-separated bases to retire'**
  String get controlsRetireHint;

  /// No description provided for @controlsUnretireHint.
  ///
  /// In en, this message translates to:
  /// **'Comma-separated bases to unretire'**
  String get controlsUnretireHint;

  /// No description provided for @logsTitle.
  ///
  /// In en, this message translates to:
  /// **'Logs'**
  String get logsTitle;

  /// No description provided for @logsRefresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get logsRefresh;

  /// No description provided for @logsClear.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get logsClear;

  /// No description provided for @logsEmpty.
  ///
  /// In en, this message translates to:
  /// **'No log lines yet — the engine writes here once it\'s running.'**
  String get logsEmpty;

  /// No description provided for @settingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// No description provided for @settingsTheme.
  ///
  /// In en, this message translates to:
  /// **'Theme'**
  String get settingsTheme;

  /// No description provided for @settingsThemeSystem.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get settingsThemeSystem;

  /// No description provided for @settingsThemeLight.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get settingsThemeLight;

  /// No description provided for @settingsThemeDark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get settingsThemeDark;

  /// No description provided for @settingsDataDirectory.
  ///
  /// In en, this message translates to:
  /// **'Data directory'**
  String get settingsDataDirectory;

  /// No description provided for @settingsMode.
  ///
  /// In en, this message translates to:
  /// **'Mode'**
  String get settingsMode;

  /// No description provided for @settingsPollInterval.
  ///
  /// In en, this message translates to:
  /// **'Poll interval'**
  String get settingsPollInterval;

  /// No description provided for @settingsAbout.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get settingsAbout;

  /// No description provided for @dashboardPower.
  ///
  /// In en, this message translates to:
  /// **'Power'**
  String get dashboardPower;

  /// No description provided for @dashboardPowerOn.
  ///
  /// In en, this message translates to:
  /// **'Live'**
  String get dashboardPowerOn;

  /// No description provided for @dashboardPowerOff.
  ///
  /// In en, this message translates to:
  /// **'Powered down'**
  String get dashboardPowerOff;

  /// No description provided for @dashboardNextCheckup.
  ///
  /// In en, this message translates to:
  /// **'Next checkup'**
  String get dashboardNextCheckup;

  /// No description provided for @dashboardLastPowerDown.
  ///
  /// In en, this message translates to:
  /// **'Last power-down'**
  String get dashboardLastPowerDown;

  /// No description provided for @dashboardNeverPoweredDown.
  ///
  /// In en, this message translates to:
  /// **'Never'**
  String get dashboardNeverPoweredDown;

  /// No description provided for @dashboardQuickActions.
  ///
  /// In en, this message translates to:
  /// **'Quick actions'**
  String get dashboardQuickActions;

  /// No description provided for @actionStart.
  ///
  /// In en, this message translates to:
  /// **'Start (auto-run)'**
  String get actionStart;

  /// No description provided for @actionCheckNow.
  ///
  /// In en, this message translates to:
  /// **'Check now'**
  String get actionCheckNow;

  /// No description provided for @actionStopAll.
  ///
  /// In en, this message translates to:
  /// **'Stop all'**
  String get actionStopAll;

  /// No description provided for @actionLast.
  ///
  /// In en, this message translates to:
  /// **'Last all'**
  String get actionLast;

  /// No description provided for @dashboardAutoBots.
  ///
  /// In en, this message translates to:
  /// **'Auto bots (app-initiated)'**
  String get dashboardAutoBots;

  /// No description provided for @dashboardAvailablePairs.
  ///
  /// In en, this message translates to:
  /// **'Redlist Pairs'**
  String get dashboardAvailablePairs;

  /// No description provided for @dashboardNoAvailablePairs.
  ///
  /// In en, this message translates to:
  /// **'No eligible pairs right now — every Red-list pair is either retired or already has an auto grid running.'**
  String get dashboardNoAvailablePairs;

  /// No description provided for @dashboardRetireDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Retire running auto bots'**
  String get dashboardRetireDialogTitle;

  /// No description provided for @dashboardRetireDialogBody.
  ///
  /// In en, this message translates to:
  /// **'Selected bots will finish naturally and never auto-recreate.'**
  String get dashboardRetireDialogBody;

  /// No description provided for @dashboardRetireSelected.
  ///
  /// In en, this message translates to:
  /// **'Retire selected'**
  String get dashboardRetireSelected;

  /// No description provided for @settingsIntegrations.
  ///
  /// In en, this message translates to:
  /// **'Integrations'**
  String get settingsIntegrations;

  /// No description provided for @integrationTradingView.
  ///
  /// In en, this message translates to:
  /// **'TradingView Desktop'**
  String get integrationTradingView;

  /// No description provided for @integrationPionex.
  ///
  /// In en, this message translates to:
  /// **'Pionex'**
  String get integrationPionex;

  /// No description provided for @fieldApiKey.
  ///
  /// In en, this message translates to:
  /// **'API key'**
  String get fieldApiKey;

  /// No description provided for @fieldApiSecret.
  ///
  /// In en, this message translates to:
  /// **'API secret'**
  String get fieldApiSecret;

  /// No description provided for @fieldHost.
  ///
  /// In en, this message translates to:
  /// **'Host'**
  String get fieldHost;

  /// No description provided for @fieldPort.
  ///
  /// In en, this message translates to:
  /// **'Port'**
  String get fieldPort;

  /// No description provided for @actionTestConnection.
  ///
  /// In en, this message translates to:
  /// **'Test connection'**
  String get actionTestConnection;

  /// No description provided for @actionSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get actionSave;

  /// No description provided for @actionCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get actionCopy;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
