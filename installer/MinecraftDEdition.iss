#define MyAppName "Minecraft D Edition"
#define MyAppPublisher "Minecraft D Edition"
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
DefaultDirName={localappdata}\Programs\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\dist
OutputBaseFilename=Minecraft.D.Edition.OfflineSetup
SetupIconFile=..\native\minecraft_d_edition.ico
UninstallDisplayIcon={app}\Minecraft D Edition Launcher.exe
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
VersionInfoVersion=1.0.0.0
VersionInfoProductName={#MyAppName}
VersionInfoDescription={#MyAppName} Installer
VersionInfoCompany={#MyAppPublisher}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional shortcuts:"

[Files]
Source: "..\dist\runtime\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Minecraft D Edition"; Filename: "{app}\Minecraft D Edition Launcher.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\Minecraft D Edition"; Filename: "{app}\Minecraft D Edition Launcher.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\Minecraft D Edition Launcher.exe"; Description: "Launch Minecraft D Edition"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent
