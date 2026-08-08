; Inno Setup script for System-Setup.
;
; Replaces the ps2exe build. A ps2exe binary decodes and executes an embedded
; script at runtime, which Defender's ML scores as a dropper
; (Trojan:Win32/Phonzy.B!ml). A conventional installer doesn't trip that.
;
; Nothing is left behind: files extract to {tmp}, the setup runs, and Windows
; clears the folder on exit. No install directory, no uninstaller, no registry.
;
; Build:  iscc /DAppVersion=1.1.1 installer.iss

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif

#define AppName "System-Setup"
#define AppPublisher "sdeepanshu13"
#define AppURL "https://github.com/sdeepanshu13/System-Setup"

[Setup]
AppId={{8F3C5A21-6D74-4B9E-A0C2-1E7B4D9F2A63}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}/issues
VersionInfoVersion={#AppVersion}
VersionInfoDescription=Windows dev machine setup - backup and restore
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
; deleteafterinstall keeps nothing on disk once the run finishes.
Source: "Setup.ps1";                  DestDir: "{tmp}"; Flags: deleteafterinstall
Source: "Setup-UI.ps1";               DestDir: "{tmp}"; Flags: deleteafterinstall
Source: "Setup-Wizard.ps1";           DestDir: "{tmp}"; Flags: deleteafterinstall
Source: "Setup-Flows.ps1";            DestDir: "{tmp}"; Flags: deleteafterinstall
Source: "restore.ps1";                DestDir: "{tmp}"; Flags: deleteafterinstall
Source: "Enable-WindowsFeatures.ps1"; DestDir: "{tmp}"; Flags: deleteafterinstall
Source: "bootstrap-dev.sh";           DestDir: "{tmp}"; Flags: deleteafterinstall
Source: "winget-packages.json";       DestDir: "{tmp}"; Flags: deleteafterinstall
Source: "vscode-extensions.txt";      DestDir: "{tmp}"; Flags: deleteafterinstall
Source: "zshrc-template";             DestDir: "{tmp}"; Flags: deleteafterinstall
Source: "p10k-template";              DestDir: "{tmp}"; Flags: deleteafterinstall
Source: "zsh-gitbash.tar.gz";         DestDir: "{tmp}"; Flags: deleteafterinstall skipifsourcedoesntexist
Source: "..\Shared\Modules\SetupCore.psm1";      DestDir: "{tmp}\Shared\Modules"; Flags: deleteafterinstall
Source: "..\Shared\Modules\SetupInventory.psm1"; DestDir: "{tmp}\Shared\Modules"; Flags: deleteafterinstall
Source: "..\Shared\Config\supabase-config.json"; DestDir: "{tmp}\Shared\Config";  Flags: deleteafterinstall

[Run]
Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{tmp}\Setup.ps1"""; \
  WorkingDir: "{tmp}"; \
  StatusMsg: "Starting System-Setup..."; \
  Flags: waituntilterminated
