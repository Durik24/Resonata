; Resonata's installer. Built by build.ps1, which passes AppVersion and PublishDir.
;
; An update is simply the next Setup run over the top: AppId stays the same, so
; it finds the installed copy, replaces it and leaves the user's data alone
; (that lives in %APPDATA%\Resonata, never in Program Files).
;
; /DTestInstall builds a variant that needs no administrator and installs under
; the user's own folder, so upgrade and uninstall can be tried without touching
; Program Files. Never publish that one.
;
; /DArch=arm64 builds the Setup for ARM64 PCs from the win-arm64 build. It's
; named Resonata-ARM64-Setup-*, so the updater of 1.1.0 and older, which takes
; the first asset named Resonata-Setup*, never fetches it for an x64 PC. Both
; share the AppId: either Setup run over the other replaces it.

#ifndef AppVersion
  #error Build this with build.ps1, which passes /DAppVersion and /DPublishDir
#endif
#ifndef Arch
  #define Arch "x64"
#endif
#if Arch == "arm64"
  #define NameTag "-ARM64"
#else
  #define NameTag ""
#endif

[Setup]
#ifdef TestInstall
AppId={{6F4A0D2B-7C51-4C8E-9B1E-TESTINSTALL00}
PrivilegesRequired=lowest
DefaultDirName={localappdata}\ResonataInstallTest
OutputBaseFilename=Resonata{#NameTag}-InstallTest-{#AppVersion}
#else
AppId={{6F4A0D2B-7C51-4C8E-9B1E-2D3F8A5C7E10}
PrivilegesRequired=admin
DefaultDirName={autopf}\Resonata
OutputBaseFilename=Resonata{#NameTag}-Setup-{#AppVersion}
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
#if Arch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
; Also ARM64 PCs, which run it emulated.
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif
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
; Setup asks Resonata to quit itself, and ends it if it won't (below). Not the
; Restart Manager as well: on ARM64 it finds the x64 build's files held by
; XtaCache, Windows' cache of emulated code, can't close that service and
; gives up, so the ARM64 Setup failed to replace the x64 build.
CloseApplications=no
RestartApplications=no
UsedUserAreasWarning=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[InstallDelete]
; The runtime's version is in this file's name, so a newer .NET left the old
; one behind. The other processor's files go after the install (DeleteOtherBuild).
Type: files; Name: "{app}\mscordaccore_*.dll"

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
  ResultCode, Attempt: Integer;
begin
  if FileExists(Path) then
  begin
    if Exec(Path, '--quit', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
      Log('Asked Resonata to quit, exit code ' + IntToStr(ResultCode))
    else
      Log('Could not run Resonata --quit, error ' + IntToStr(ResultCode));
  end
  else
    Log('Resonata not found at ' + Path);

  { Whatever is left goes the hard way: a copy that wouldn't quit, and one that
    quit but never ended, which 1.1.0 could do, still holding its files.
    "Quit" saved its notes and settings. taskkill says 128 once none is left. }
  for Attempt := 1 to 20 do
  begin
    if not Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM Resonata.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then Exit;
    if ResultCode = 128 then Exit;
    Log('Ended a Resonata that was still running, taskkill ' + IntToStr(ResultCode));
    Sleep(250);
  end;
end;

procedure DeleteWithRetries(Path: String);
var
  Attempt: Integer;
begin
  { Windows' cache of emulated code can hold an x64 file for a moment. }
  for Attempt := 1 to 20 do
  begin
    if not FileExists(Path) then Exit;
    if DeleteFile(Path) then
    begin
      Log('Deleted ' + Path);
      Exit;
    end;
    Sleep(500);
  end;
  Log('Could not delete ' + Path);
end;

{ What the other processor's build left, when this Setup goes over it. }
procedure DeleteOtherBuild();
var
  Dir: String;
  Found: TFindRec;
  Names: TStringList;
  I: Integer;
begin
  Dir := ExpandConstant('{app}\');
  Names := TStringList.Create;
  try
#if Arch == "arm64"
    Names.Add('D3DCompiler_47_cor3.dll');
    if FindFirst(Dir + '*amd64*.dll', Found) then
#else
    if FindFirst(Dir + '*arm64*.dll', Found) then
#endif
    try
      repeat
        Names.Add(Found.Name);
      until not FindNext(Found);
    finally
      FindClose(Found);
    end;
    for I := 0 to Names.Count - 1 do
      DeleteWithRetries(Dir + Names[I]);
  finally
    Names.Free;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then DeleteOtherBuild();
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
