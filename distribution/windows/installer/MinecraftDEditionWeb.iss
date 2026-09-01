; Windows GitHub-backed web installer. macOS uses a signed app bundle and DMG.
#define MyAppName "Minecraft: D Edition"
#define MyAppPathName "Minecraft D Edition"
#define MyAppPublisher "Minecraft: D Edition"
#define MyAppURL "https://github.com/MinecraftDEdition/Minecraft-D-Edition"
#define MyAppVersion GetEnv("MDE_VERSION")

[Setup]
AppId={{1B74B195-260A-4E71-B53E-94A6A9E4FB0F}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}/issues
AppUpdatesURL={#MyAppURL}/releases/tag/Test
DefaultDirName={localappdata}\Programs\{#MyAppPathName}
DefaultGroupName={#MyAppPathName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\..\..\dist
OutputBaseFilename=Minecraft.D.Edition.Setup
SetupIconFile=..\..\..\native\minecraft_d_edition.ico
UninstallDisplayIcon={app}\Minecraft D Edition Launcher.exe
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
VersionInfoVersion=1.0.0.0
VersionInfoProductName={#MyAppName}
VersionInfoDescription={#MyAppName} Web Installer
VersionInfoCompany={#MyAppPublisher}
UninstallDisplayName={#MyAppName}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional shortcuts:"

[Files]
Source: "..\..\..\Minecraft D Edition Launcher.exe"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\Minecraft D Edition"; Filename: "{app}\Minecraft D Edition Launcher.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\Minecraft D Edition"; Filename: "{app}\Minecraft D Edition Launcher.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\Minecraft D Edition Launcher.exe"; Description: "Download and launch Minecraft: D Edition"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: files; Name: "{app}\Minecraft D Edition.exe"
Type: files; Name: "{app}\Minecraft D Edition Launcher.update.exe"
Type: files; Name: "{app}\EOSSDK-Win64-Shipping.dll"
Type: files; Name: "{app}\discord_partner_sdk.dll"
Type: files; Name: "{app}\SDL3.dll"
Type: files; Name: "{app}\.mde-installed-manifest.txt"
Type: files; Name: "{app}\.mde-installed-manifest.txt.new"
Type: filesandordirs; Name: "{app}\.mde-update"
Type: filesandordirs; Name: "{app}\assets"
Type: filesandordirs; Name: "{app}\data\minecraft"
Type: filesandordirs; Name: "{app}\licenses"
Type: files; Name: "{app}\data\eos.example.json"
Type: files; Name: "{app}\data\eos.client.json"
Type: dirifempty; Name: "{app}\data"
Type: dirifempty; Name: "{app}"
