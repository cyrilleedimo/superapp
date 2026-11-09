; Installeur Windows (Inno Setup 6) — produit « Ovia-Setup.exe ».
; Compilé par la CI ; en local : iscc installer\setup.iss  (après flutter build windows)
#define AppName "Ovia"
#define AppVersion GetEnv("APP_VERSION")
#if AppVersion == ""
  #define AppVersion "1.0.0"
#endif

[Setup]
AppId={{6F1C9C2E-3B7A-4C55-9D2E-8A41B7E0C3D9}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=[LEGAL ENTITY]
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
OutputDir=..\build\installer
OutputBaseFilename={#AppName}-Setup-{#AppVersion}
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\superapp.exe
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequiredOverridesAllowed=dialog

[Languages]
Name: "french"; MessagesFile: "compiler:Languages\French.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\superapp.exe"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\superapp.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\superapp.exe"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
