; GoPray.iss — the Windows installer (PLAN.md §5, PM rulings 2026-10-23). Inno Setup 6.
; Per user, no admin, no UAC: {localappdata}\Programs\Go Pray. Start menu shortcut, optional desktop shortcut,
; "Launch Go Pray" at the end. The installer never creates the Task Scheduler task: the app does that when the
; person finishes Setup with "Launch at login" on (so a hand-copied exe works the same way).
; Uninstall: `GoPray.exe --uninstall-task` removes the task and asks a running copy to quit (it quits only
; between prayers), then the files go. The data folder (%LOCALAPPDATA%\GoPray: settings, state, logs, caches)
; is removed only if the person says yes. Uninstalling during a block cannot remove the running exe until the
; block ends (accepted: an admin action, never quicker than the block, CONTRACT-NOTES #43).
;
; Built by scripts\build-installer.ps1:  ISCC /DAppVersion=<ver> /DPublishDir=<dir> /DOutDir=<dir> GoPray.iss

#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif
#ifndef PublishDir
  #error PublishDir is required (the self-contained publish folder)
#endif
#ifndef OutDir
  #define OutDir "out"
#endif

[Setup]
AppId={{6F3C1E52-8B0A-4C5D-9E1B-2D7A4F9C3B61}
AppName=Go Pray
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

[Icons]
Name: "{autoprograms}\Go Pray"; Filename: "{app}\GoPray.exe"
Name: "{autodesktop}\Go Pray"; Filename: "{app}\GoPray.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\GoPray.exe"; Description: "Launch Go Pray"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; Removes the task "Go Pray" and asks a running copy to quit (only between prayers); waits up to 10 s.
Filename: "{app}\GoPray.exe"; Parameters: "--uninstall-task"; Flags: runhidden waituntilterminated; RunOnceId: "RemoveTask"

[Code]
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
        DelTree(Data, True, True, True);
  end;
end;
