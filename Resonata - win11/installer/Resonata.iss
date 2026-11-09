; Resonata's installer. Built by build.ps1, which passes AppVersion and PublishDir.
;
; An update is simply the next Setup run over the top: AppId stays the same, so
; it finds the installed copy, replaces it and leaves the user's data alone
; (that lives in %APPDATA%\Resonata, never in Program Files).
;
; /DTestInstall builds a variant that needs no administrator and installs under
; the user's own folder, so upgrade and uninstall can be tried without touching
; Program Files. Never publish that one.

#ifndef AppVersion
  #error Build this with build.ps1, which passes /DAppVersion and /DPublishDir
#endif

[Setup]
#ifdef TestInstall
AppId={{6F4A0D2B-7C51-4C8E-9B1E-TESTINSTALL00}
PrivilegesRequired=lowest
DefaultDirName={localappdata}\ResonataInstallTest
OutputBaseFilename=Resonata-InstallTest-{#AppVersion}
#else
AppId={{6F4A0D2B-7C51-4C8E-9B1E-2D3F8A5C7E10}
PrivilegesRequired=admin
DefaultDirName={autopf}\Resonata
OutputBaseFilename=Resonata-Setup-{#AppVersion}
#endif
AppName=Resonata
AppVersion={#AppVersion}
AppVerName=Resonata {#AppVersion}
AppPublisher=Resonata
AppPublisherURL=https://github.com/Durik24/Resonata
AppSupportURL=https://github.com/Durik24/Resonata/issues
AppUpdatesURL=https://github.com/Durik24/Resonata/releases
VersionInfoVersion={#AppVersion}
VersionInfoProductName=Resonata
VersionInfoProductVersion={#AppVersion}
VersionInfoProductTextVersion={#AppVersion}
VersionInfoDescription=Resonata Setup
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.19041
DisableProgramGroupPage=yes
DisableDirPage=auto
OutputDir=..\out
SetupIconFile=..\src\Assets\Resonata.ico
UninstallDisplayIcon={app}\Resonata.exe
UninstallDisplayName=Resonata
WizardStyle=modern
Compression=lzma2/ultra64
SolidCompression=yes
; Setup asks Resonata to quit itself (below); this is only the fallback.
CloseApplications=force
RestartApplications=no
UsedUserAreasWarning=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#PublishDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Resonata"; Filename: "{app}\Resonata.exe"
Name: "{autodesktop}\Resonata"; Filename: "{app}\Resonata.exe"; Tasks: desktopicon

[Run]
; As the signed-in user, not elevated: an elevated Resonata couldn't take files
; dragged from Explorer. Runs after a silent update too, which is what restarts it.
Filename: "{app}\Resonata.exe"; Description: "{cm:LaunchProgram,Resonata}"; Flags: nowait postinstall runasoriginaluser

[Code]
procedure AskResonataToQuit(Path: String);
var
  ResultCode: Integer;
begin
  if not FileExists(Path) then
  begin
    Log('Resonata not found at ' + Path);
    Exit;
  end;
  if Exec(Path, '--quit', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    Log('Asked Resonata to quit, exit code ' + IntToStr(ResultCode))
  else
    Log('Could not run Resonata --quit, error ' + IntToStr(ResultCode));

  { Still there: left running, its files couldn't be removed. }
  if ResultCode <> 0 then
    Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM Resonata.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  AskResonataToQuit(ExpandConstant('{app}\Resonata.exe'));
  Result := '';
end;

function InitializeUninstall(): Boolean;
begin
  AskResonataToQuit(ExpandConstant('{app}\Resonata.exe'));
  Result := True;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Question: String;
  Answer: Integer;
begin
  if CurUninstallStep <> usPostUninstall then Exit;

  { The app registered this itself, on its first run. }
  RegDeleteValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', 'Resonata');

  Question := 'Also delete your Resonata notes, to-dos and settings?';

  { Default No, which is also the answer in a silent uninstall. }
  Answer := SuppressibleMsgBox(Question, mbConfirmation, MB_YESNO or MB_DEFBUTTON2, IDNO);
  Log('Delete user data answer: ' + IntToStr(Answer));
  if Answer = IDYES then
  begin
    DelTree(ExpandConstant('{userappdata}\Resonata'), True, True, True);
    DelTree(ExpandConstant('{localappdata}\Resonata'), True, True, True);
  end;
end;
