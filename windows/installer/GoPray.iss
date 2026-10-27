; GoPray.iss — the Windows installer (PLAN.md §5, PM rulings 2026-10-23). Inno Setup 6.
; Per user, no admin, no UAC: {localappdata}\Programs\Go Pray. Start menu shortcut, optional desktop shortcut,
; "Launch Go Pray" at the end. The installer never creates the Task Scheduler task: the app does that when the
; person finishes Setup with "Launch at login" on (so a hand-copied exe works the same way).
; Uninstall: `GoPray.exe --uninstall-task` removes the task and asks a running copy to quit (it quits only
; between prayers), then the files go. The data folder (%LOCALAPPDATA%\GoPray: settings, state, logs, caches)
; is removed only if the person says yes. Uninstalling during a block cannot remove the running exe until the
; block ends (accepted: an admin action, never quicker than the block, CONTRACT-NOTES #43).
;
; Upgrade over a running copy (0.2.1, PM ruling 2026-10-24): before copying files, PrepareToInstall pauses the
; "Go Pray" task (no tick can start the exe mid-copy), then, if a copy holds the instance mutex, posts the same
; "GoPray.Quit" broadcast the uninstaller uses (0.1.x and 0.2.0 already understand it; a new `--quit` flag would
; not reach them) and waits up to 10 s. The app quits only between prayers, so a copy that is still there means a
; block is up: Setup stops with "Go Pray is in a prayer block. Run Setup again after the block ends." The task is
; resumed after the files are in (or when Setup stops). Inno's own CloseApplications stays off: nothing else is closed.
;
; Built by scripts\build-installer.ps1:  ISCC /DAppVersion=<ver> /DPublishDir=<dir> /DOutDir=<dir> GoPray.iss
; Tests only (scripts\test-installer-upgrade.ps1) override the names so a test never touches the real app:
;   /DAppIdValue=… /DMutexName=… /DQuitMessage=… /DTaskName=…

#ifndef AppVersion
  #define AppVersion "0.3.4"
#endif
#ifndef AppIdValue
  #define AppIdValue "{{6F3C1E52-8B0A-4C5D-9E1B-2D7A4F9C3B61}"
#endif
#ifndef MutexName
  #define MutexName "Local\GoPray.Instance"
#endif
#ifndef QuitMessage
  #define QuitMessage "GoPray.Quit"
#endif
#ifndef TaskName
  #define TaskName "Go Pray"
#endif
#ifndef PublishDir
  #error PublishDir is required (the self-contained publish folder)
#endif
#ifndef OutDir
  #define OutDir "out"
#endif

[Setup]
AppId={#AppIdValue}
#ifdef TestRun
AppName=Go Pray installer test
; a test install leaves no uninstall entry, no shortcuts and no uninstaller
Uninstallable=no
CreateUninstallRegKey=no
#else
AppName=Go Pray
#endif
AppVersion={#AppVersion}
AppVerName=Go Pray {#AppVersion}
AppPublisher=Ahmed Elgazar
AppPublisherURL=https://github.com/simkinselgazar-rgb/go-pray
AppSupportURL=https://github.com/simkinselgazar-rgb/go-pray/issues
AppUpdatesURL=https://github.com/simkinselgazar-rgb/go-pray/releases
DefaultDirName={localappdata}\Programs\Go Pray
DefaultGroupName=Go Pray
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
OutputDir={#OutDir}
OutputBaseFilename=GoPray-Setup-{#AppVersion}
SetupIconFile=..\assets\GoPray.ico
UninstallDisplayIcon={app}\GoPray.exe
UninstallDisplayName=Go Pray
WizardStyle=modern
Compression=lzma2/ultra64
SolidCompression=yes
LZMAUseSeparateProcess=yes
LZMANumBlockThreads=4
; We close our own app (see [UninstallRun]); never ask Restart Manager to close other apps.
CloseApplications=no
RestartApplications=no
VersionInfoVersion={#AppVersion}
VersionInfoProductName=Go Pray
VersionInfoDescription=Go Pray installer

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Shortcuts:"; Flags: unchecked

[Files]
; The whole self-contained publish, minus symbols (they name debug-only source files; PM ruling 2026-10-23).
Source: "{#PublishDir}\*"; DestDir: "{app}"; Excludes: "*.pdb"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\..\LICENSE"; DestDir: "{app}\licenses"; DestName: "GoPray-LICENSE.txt"; Flags: ignoreversion
Source: "..\..\audio\LICENSES.md"; DestDir: "{app}\licenses"; DestName: "audio-LICENSES.md"; Flags: ignoreversion

#ifndef TestRun
[Icons]
Name: "{autoprograms}\Go Pray"; Filename: "{app}\GoPray.exe"
Name: "{autodesktop}\Go Pray"; Filename: "{app}\GoPray.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\GoPray.exe"; Description: "Launch Go Pray"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; Removes the task "Go Pray" and asks a running copy to quit (only between prayers); waits up to 10 s.
Filename: "{app}\GoPray.exe"; Parameters: "--uninstall-task"; Flags: runhidden waituntilterminated; RunOnceId: "RemoveTask"
#endif

[Code]
const
  BlockedLine = 'Go Pray is in a prayer block. Run Setup again after the block ends.';

var
  TaskPaused: Boolean;

function RegisterWindowMessage(lpString: String): Cardinal;
  external 'RegisterWindowMessageW@user32.dll stdcall';

{ Pause or resume the Task Scheduler task. A missing task is fine (the app registers it at launch). }
procedure SetTask(Enable: Boolean);
var
  Code: Integer;
  Arg: String;
begin
  if Enable then Arg := '/ENABLE' else Arg := '/DISABLE';
  if Exec(ExpandConstant('{sys}\schtasks.exe'), '/Change /TN "{#TaskName}" ' + Arg, '', SW_HIDE, ewWaitUntilTerminated, Code) then
  begin
    if not Enable then TaskPaused := (Code = 0)
    else if Code = 0 then TaskPaused := False;
    Log(Format('task "{#TaskName}" %s: exit %d', [Arg, Code]));
  end;
end;

procedure ResumeTask;
begin
  if TaskPaused then SetTask(True);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  I: Integer;
begin
  Result := '';
  SetTask(False);
  if not CheckForMutexes('{#MutexName}') then
  begin
    Log('no running copy');
    Exit;
  end;
  Log('a running copy holds {#MutexName}: asking it to quit');
  PostBroadcastMessage(RegisterWindowMessage('{#QuitMessage}'), 0, 0);
  for I := 1 to 40 do
  begin
    if not CheckForMutexes('{#MutexName}') then Break;
    Sleep(250);
  end;
  if CheckForMutexes('{#MutexName}') then
  begin
    Log('still running after 10 s: a prayer block is up');
    ResumeTask;
    Result := BlockedLine;
  end
  else Log('the running copy quit');
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then ResumeTask;
end;

procedure DeinitializeSetup;
begin
  ResumeTask;     { Setup cancelled or failed after the pause: never leave the task off }
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Data: String;
begin
  if CurUninstallStep = usPostUninstall then
  begin
    Data := ExpandConstant('{localappdata}\GoPray');
    if DirExists(Data) and (not UninstallSilent) then
      if MsgBox('Also remove your Go Pray settings and data?' + #13#10 + #13#10 +
                'This is your city, prayer-time choices and the app''s notes. Keep them if you plan to install Go Pray again.',
                mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
      begin
        DelTree(Data, True, True, True);
        // v2: the emergency-exit mirror (PLAN-v2 §2.4: a full uninstall with "Yes" resets the exits; an admin act).
        if DirExists(ExpandConstant('{userappdata}\GoPray')) then
          DelTree(ExpandConstant('{userappdata}\GoPray'), True, True, True);
      end;
  end;
end;
