; Rime 更新器 Windows 安装包（Inno Setup 6）
; 用法：ISCC.exe installer.iss
; 产物：<repo>\dist\RimeUpdater-v<版本>-Setup.exe

[Setup]
AppId={{8F3C2A1B-7D4E-4B9A-9C6F-2E5D1A0B3C47}
AppName=Rime 更新器
AppVersion=1.0.0
AppVerName=Rime 更新器 1.0.0
AppPublisher=viui798
AppPublisherURL=https://github.com/viui798/rime-updater
AppSupportURL=https://github.com/viui798/rime-updater
DefaultDirName={localappdata}\Programs\RimeUpdater
DefaultGroupName=Rime 更新器
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\..\dist
OutputBaseFilename=RimeUpdater-v1.0.0-Setup
SetupIconFile=runner\resources\app_icon.ico
UninstallDisplayIcon={app}\rime_updater.exe
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
LicenseFile=..\..\LICENSE
VersionInfoVersion=1.0.0.0
VersionInfoCompany=viui798
VersionInfoDescription=Rime 更新器 安装程序
VersionInfoProductName=Rime 更新器
VersionInfoProductVersion=1.0.0

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "其他:"; Flags: unchecked

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Rime 更新器"; Filename: "{app}\rime_updater.exe"; WorkingDir: "{app}"
Name: "{group}\卸载 Rime 更新器"; Filename: "{uninstallexe}"
Name: "{autodesktop}\Rime 更新器"; Filename: "{app}\rime_updater.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\rime_updater.exe"; Description: "启动 Rime 更新器"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: files; Name: "{group}\Rime 更新器.lnk"
Type: files; Name: "{autodesktop}\Rime 更新器.lnk"
; Flutter 产物里的 data 子目录会留下空壳，卸载时整棵清掉
Type: filesandordirs; Name: "{app}\data"

[Code]
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
  begin
    // 正常情况下文件已删完，这里只清空目录；若被其他进程占用会留待下次删除
    RemoveDir(ExpandConstant('{app}'));
  end;
end;
