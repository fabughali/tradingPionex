; TradingPionex Windows installer, compiled by .github/workflows/windows-build.yml
; with /DMyAppVersion=<pubspec.yaml version>. Installs the Release folder (GUI
; plus trading_pionex_engine.exe, which must stay next to trading_pionex.exe)
; per user, with Start Menu/Desktop shortcuts and an uninstaller. Runtime data
; lives in %USERPROFILE%\.tradingpionex and is never touched by install or
; uninstall.
#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif

#define MyAppName "TradingPionex"
#define MyAppExeName "trading_pionex.exe"
#define MyEngineExeName "trading_pionex_engine.exe"

[Setup]
AppId={{6C1E9B52-3F4A-4E7D-9B1C-8A2D5F0E7C41}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppName}
AppSupportURL=https://github.com/fabughali/tradingPionex
DefaultDirName={localappdata}\Programs\{#MyAppName}
PrivilegesRequired=lowest
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=..\installer_output
OutputBaseFilename=TradingPionex-Setup-{#MyAppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
SetupIconFile=app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
ArchitecturesInstallIn64BitMode=x64compatible
; An update must not overwrite files the running app or engine holds open.
CloseApplications=yes
; Tells Windows to refresh its icon cache after install, so an update's new
; icon shows on the shortcuts and taskbar right away, not the cached old one.
ChangesAssociations=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "vc_redist.x64.exe"; DestDir: "{tmp}"; Flags: deleteafterinstall

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"
; Always created (per the user): every install and update puts it back.
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"

[Run]
Filename: "{tmp}\vc_redist.x64.exe"; Parameters: "/install /quiet /norestart"; StatusMsg: "Installing the Microsoft Visual C++ Runtime (one-time)..."; Check: VCRedistNeedsInstall; Flags: waituntilterminated
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent

[Code]
// Stops setup while the app or its engine is running, so an update never
// replaces files under a live engine (it may be watching real trades).
function IsRunning(ExeName: String): Boolean;
var
  ResultCode: Integer;
begin
  Result := Exec(ExpandConstant('{cmd}'),
    '/C tasklist /FI "IMAGENAME eq ' + ExeName + '" | find /I "' + ExeName + '" >NUL',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode) and (ResultCode = 0);
end;

function InitializeSetup: Boolean;
begin
  Result := True;
  while IsRunning('{#MyAppExeName}') or IsRunning('{#MyEngineExeName}') do
  begin
    if MsgBox('TradingPionex or its engine is running.' + #13#10 +
      'Power it OFF in the app and close the app, then click OK.' + #13#10 +
      'Click Cancel to stop the setup.', mbError, MB_OKCANCEL) = IDCANCEL then
    begin
      Result := False;
      Exit;
    end;
  end;
end;

function VCRedistNeedsInstall: Boolean;
var
  Installed: Cardinal;
begin
  Result := True;
  if RegQueryDWordValue(HKLM64, 'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\X64', 'Installed', Installed) then
    if Installed = 1 then
      Result := False;
end;
