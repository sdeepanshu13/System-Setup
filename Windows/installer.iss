; Inno Setup script for the System-Setup launcher.
;
; This deliberately does NOT bundle the application. It ships only the small
; bootstrap script, which fetches the current source at run time.
;
; Why: Defender's cloud protection scores unsigned binaries largely on
; reputation, and reputation is per file hash. Bundling the app meant every push
; produced a brand-new binary with none, so downloads were quarantined
; (Trojan:Win32/Wacatac, Phonzy - both ML heuristics).
;
; With the payload outside the binary, this file only changes when the bootstrap
; logic changes. The hash stays put across app releases and can accumulate
; trust, while users still get the newest code on every run.
;
; LauncherVersion is deliberately fixed and separate from the app version, so
; routine releases don't perturb the binary.
;
; Build:  iscc installer.iss

#define LauncherVersion "1.0.0"
#define AppName "System-Setup"
#define AppPublisher "sdeepanshu13"
#define AppURL "https://github.com/sdeepanshu13/System-Setup"

[Setup]
AppId={{8F3C5A21-6D74-4B9E-A0C2-1E7B4D9F2A63}
AppName={#AppName}
AppVersion={#LauncherVersion}
AppVerName={#AppName}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}/issues
VersionInfoVersion={#LauncherVersion}
VersionInfoDescription=System-Setup launcher
VersionInfoCompany={#AppPublisher}
VersionInfoProductName={#AppName}

; Run-once launcher: no install dir, no uninstaller, no Add/Remove entry.
CreateAppDir=no
Uninstallable=no
PrivilegesRequired=admin
OutputDir=..\dist
OutputBaseFilename=Setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
DisableWelcomePage=yes
DisableReadyPage=yes
DisableFinishedPage=yes
ShowLanguageDialog=no
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "..\install.ps1"; DestDir: "{tmp}"; Flags: deleteafterinstall

[Run]
Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{tmp}\install.ps1"""; \
  WorkingDir: "{tmp}"; \
  StatusMsg: "Fetching the latest version..."; \
  Flags: waituntilterminated
