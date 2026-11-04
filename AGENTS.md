# AGENTS.md — rime 更新器 工作记录与交接

> 给接手的 agent / 未来的自己：先读本文，再动手。约 2 分钟。

## 0. 接手清单（新设备 / 新 agent，5 分钟）

1. 拉代码：`git clone https://github.com/viui798/rime-updater && cd rime-updater`
   （原开发机本地目录 `/Users/viui/Desktop/rime更新器`，方案仓库在 `/Users/viui/Desktop/芝士虎整`）
2. 装 Flutter stable（原机器为 3.47.9 / Dart 3），然后 `cd app && flutter pub get`
   （项目只用纯 Dart 依赖 `archive` / `crypto` / `path`，不需要 CocoaPods）
3. 跑验证：`dart analyze`、`flutter test`，当前应为 **43 项全部通过**
4. 构建：
   - macOS：`DEVELOPER_DIR=/Applications/Xcode-16.2.0.app/Contents/Developer flutter build macos --release`
   - Windows：在 Windows 机器上 `flutter build windows --release`，产物
     `build\windows\x64\runner\Release\rime_updater.exe`（需要 VS「使用 C++ 的桌面开发」）
   - Android：`flutter build apk --debug`，产物
     `build/app/outputs/flutter-apk/app-debug.apk`。本机 JDK 17 在 `~/android/jdk17`，
     SDK 在 `/opt/homebrew/share/android-commandlinetools`（构建时设 `JAVA_HOME` / `ANDROID_HOME`）
5. 启动后先勾选设备 → 点「检查更新」。**启动时故意不联网**，不要改回自动检查
6. 读完第 2/3/4/6/7 节；本次会话结束前更新第 6 节与第 9 节

运行数据都不在仓库里（换设备只同步代码，个人数据靠 WebDAV 同步库）：

| 内容 | macOS | Windows |
|---|---|---|
| 设置 / 设备 ID / 同步状态 | `~/Library/Application Support/CheeseTigerUpdater/` | `%LOCALAPPDATA%\cheese-tiger\` |
| 换方案 / 同步前备份 | 同上 `switch-backups/` | 同上 `switch-backups/` |
| 下载缓存 | `~/Library/Caches/cheese-tiger` | `%LOCALAPPDATA%\cheese-tiger\cache` |
| Rime 用户目录 | `~/Library/Rime`、`~/.local/share/fcitx5/rime`、Cobra | `%APPDATA%\Rime`、扫描 `%APPDATA%` / `%LOCALAPPDATA%` |

## 1. 项目是什么

**通用 Rime 方案更新器**：默认对接芝士虎整（虎码 Rime 整合包）仓库，也支持在
「GitHub 方案」里填任意方案仓库，或从本地 zip 安装。品牌已统一为「Rime 更新器 /
RIME UPDATER」，界面标题、窗口标题、Android 应用名都不再出现具体方案名。
独立仓库维护：

- 本仓库：<https://github.com/viui798/rime-updater>（公开，GPL-3.0）
- 方案仓库：<https://github.com/viui798/viui-tiger-sentense>（公开，GPL-3.0）
- 本地目录：`/Users/viui/Desktop/rime更新器`
- 方案仓库本地目录：`/Users/viui/Desktop/芝士虎整`

职责边界：

| 谁 | 做什么 |
|---|---|
| 本仓库 | 客户端：识别用户目录、下载包、校验、覆盖、部署、备份回滚、图形界面 |
| 方案仓库 | 发版：`tools/make_release_delta.py` 生成 `*-update.zip`，完整包 `make_release_zip.py` |

## 2. 当前状态（2026-11-04）

- `app/`：**主客户端**，Flutter 原生桌面应用（Dart），一套代码覆盖 macOS / Windows，
  平台目录已生成（macos / windows / android / ios）；界面为 Material 3 原生窗口
- `app/` 已验证：`dart analyze` 无问题，`flutter test` 41 项通过（过滤规则、增量包解包、
  快照回滚、扁平/带目录 zip、版本推断、Rime 包识别、换方案备份与清理、手动目录与重命名、
  无变化跳过、云同步上传/删除/下载/在线编辑、同步库文件树、WebDAV 客户端、首页与弹窗渲染）
- **启动不自动请求 GitHub**：打开 App 只有本地探测；点「检查更新」才发请求，检查结果
  缓存 10 分钟，期间「仅预演 / 一键更新」复用同一 ReleaseInfo，不再重复请求
- 设备区右上角「+」可手动指定 Rime 用户目录，保存到设置的 `custom_dirs`，
  名称存在 `custom_names`，手动设备可点铅笔改名
- 每个设备行末尾有「⋮」菜单，可「删除设备」：自动识别的目录写进设置 `hidden_dirs`，
  之后不再被探测到（要恢复只能点「+」手动添加，添加时会自动从 `hidden_dirs` 移除）；
  手动添加的设备删除时只移除 `custom_dirs` / `custom_names`；删除不会动任何 Rime 文件
- Windows 实机已跑通完整链路（2026-11-04 20:32）：界面「一键更新」把
  小狼毫 0.3.1、虎韵 0.3.2 同时更新到 v0.3.23，各生成快照（覆盖 5 / 新增 3），
  WeaselServer 于 20:32:25 重启、虎韵 build 于 20:32:42 重建；回滚尚未实跑
- 支持**从本地 zip 安装**任意方案包（不限芝士虎整）：沿用同一套用户数据过滤、快照与部署；
  zip 前缀会自动识别 `update/`、单层方案目录或扁平结构
- **换方案向导**：备份个人数据 → 清空旧运行文件（lua/opencc/models/dicts 等与根目录旧
  yaml）→ 安装新包 → 恢复个人数据 → 部署；备份在
  `~/Library/Application Support/CheeseTigerUpdater/switch-backups/<时间戳>/<前端名>/`
- **云同步（WebDAV，按前端共用同步库）**：远端行「云同步」弹窗配置地址 / 账号 / 密码 /
  本机名称；云端结构 `CheeseTigerSync/<kind>/files/<相对路径>` + 同目录 `manifest.json`
  （`devices` 与 `files` 两个列表，后者记录 `path/by/by_name/at`）。
  「上传本机」按 `collectUserData` 批量上传（含 `*.userdb` 目录会展开成具体文件）；
  「添加文件」用系统文件选择框只上传单个文件（限制在该设备目录内）；
  「下载云端」写入同步库全部文件，覆盖前 `backupUserData` 到 `switch-backups`，
  成功后按设置自动部署；文件列表里可单个删除云端文件（DELETE，本机不动），
  `*.userdb` 在界面上合并成一组、整组删除；配置好的地址下次打开弹窗会自动读取清单。
  设备 ID 持久化在 `<appSupport>/sync-state.json`。未用 PROPFIND / 目录列表
- **同步库文件管理器**：主界面「同步库」入口打开 `SyncLibraryDialog`（700×520 的 Dialog）：
  根层列出勾选的各端，进入后按 `listEntries` 把文件路径渲染成文件夹树；
  右上角「+」可上传（根层先选端，进层后直接用当前端，限制在该端目录内）；
  点文本文件（yaml/txt/lua/json/md 等）可在线编辑并保存回云端（`writeCloudFile` 更新清单时间），
  点 `*.userdb` 或二进制文件显示说明并可整组删除
- **macOS 安装包已产出**：`app/build/macos/Build/Products/Release/RimeUpdater.app`（45.6MB），
  实跑确认窗口标题、三前端识别、远端 v0.3.23 检查与预演 8 文件均正常
- 本机 Xcode 安装在 `/Applications/Xcode-16.2.0.app`，全局 `xcode-select` 仍指向
  CommandLineTools；构建时用
  `DEVELOPER_DIR=/Applications/Xcode-16.2.0.app/Contents/Developer flutter build macos`，
  或执行一次 `sudo xcode-select --switch /Applications/Xcode-16.2.0.app/Contents/Developer`
- **已关闭 App Sandbox**：Flutter 模板默认开启沙盒，会禁止读取 `~/Library/Rime` 与联网，
  已从 `macos/Runner/{DebugProfile,Release}.entitlements` 移除 `app-sandbox`
- `update_desktop.py`：Python 核心逻辑 + 命令行（纯标准库，作为参照实现与 CLI 保留）
- `gui_app.py`：Python 本地 Web UI 服务（`127.0.0.1:8765`），作为备用界面
- `web/`：Python 版界面（`index.html` / `app.js` / `style.css`）
- `build_app.py`：Python 版打包，生成 macOS `dist/RimeUpdater.app`、Windows 启动器
- Python 版已实测：mac 鼠须管 / 小企鹅（Fcitx5）/ 元书（Cobra）三前端，v0.3.23 增量包
  8 文件、SHA256 通过、部署执行成功、元书提示手动
- 快照与回滚已在临时目录实测：覆盖/新增/删除均能正确还原，版本标记同步回退
- 远端选择已验证：优先选中 `cheese-tiger-v0.3.23-update.zip`
- 匿名可访问：不设 `GITHUB_TOKEN` 也能拉取 Release（token 仅避开 API 限流）
- Windows（小狼毫 / 虎韵）已在实机验证：同时识别小狼毫（注册表 `RimeUserDir` →
  `%APPDATA%\Rime`）与虎韵（`%LOCALAPPDATA%\Tigrime\Rime`）；虎韵部署调用
  `Tigrime.Deployer.exe`（无参数，约 26 秒，自动停/起服务），小狼毫仍走
  `WeaselServer /q` + `WeaselDeployer /deploy`
- **Android（同文 / Trime）**：共用同一套 Dart 逻辑，目标目录 `/storage/emulated/0/rime`；
  启动请求 `MANAGE_EXTERNAL_STORAGE`（自用分发，不适合上架）；部署无法自动触发，
  提示用户在输入法里刷新；现支持公共目录添加与 Shizuku，见第 6 节第 39 条。模拟器（API 35）已跑通
  检查 / 预演 / 正式更新，**未在 Android 实机验证**
- iOS 平台目录已生成，更新逻辑尚未接入；另提供 `ios/scripting/` 下的
  Scripting App 更新器（无需开发者账号）：已支持检查 / 预演 / 更新 / 本地 zip /
  备份回滚 / 换方案 / 任意 GitHub 仓库，**未真机验证**

## 3. 文件说明

| 文件 | 说明 |
|---|---|
| `app/` | Flutter 主客户端：`lib/main.dart`、`lib/core/`、`lib/ui/`、`test/` |
| `app/lib/core/rime_profile.dart` | 前端探测、版本读取、`shouldCopy` 过滤、备份列表 |
| `app/lib/core/android_platform.dart` | Android 存储权限请求与系统文件选择（MethodChannel） |
| `app/lib/core/github_client.dart` | Release 拉取、下载、SHA256 校验、缓存 |
| `app/lib/core/package_preparer.dart` | 远端包准备：增量优先、`full_required` 回退完整包、缓存复用 |
| `app/lib/core/local_package.dart` | 系统文件 / 目录选择框、本地 zip 版本推断 |
| `app/lib/core/zip_installer.dart` | 增量包解包、快照、回滚（基于 `archive` 包） |
| `app/lib/core/scheme_switcher.dart` | 换方案：收集个人数据、备份、清理旧运行文件、恢复 |
| `app/lib/core/deployer.dart` | 探测小狼毫 / 虎韵安装路径，按前端执行部署（异步，避免界面卡住） |
| `app/lib/core/webdav_client.dart` | 极简 WebDAV 客户端：MKCOL / PUT / GET / DELETE + Basic Auth（路径逐段编码） |
| `app/lib/core/sync_service.dart` | 云同步：同步库清单、文件树、上传/删除/下载、在线编辑 |
| `app/lib/ui/app_theme.dart` | 设计 token 与全局 ThemeData（v3 静序：雾白 + 淡紫，见根目录 `DESIGN.md`） |
| `app/lib/ui/sync_dialog.dart` | 云同步弹窗：WebDAV 配置、同步库文件管理、上传 / 下载 |
| `app/lib/ui/sync_library_dialog.dart` | 文件夹式同步库管理器：浏览、上传、在线编辑、删除 |
| `app/lib/ui/local_zip_dialog.dart` / `remote_scheme_dialog.dart` / `switch_scheme_dialog.dart` / `settings_dialog.dart` | 四个入口弹窗 |
| `app/test/` | 8 个测试文件，覆盖过滤、解包、回滚、同步、WebDAV、界面 |
| `app/tool/verify.dart` | 真实下载（走缓存）+ 对首个目录预演，不打开界面 |
| `app/tool/make_dmg.sh` | 生成 macOS DMG（含「应用程序」软链接） |
| `app/android/app/src/main/kotlin/com/viui798/rime_updater/MainActivity.kt` | Android MethodChannel：所有文件权限、系统文件选择 |
| `ios/scripting/cheese-tiger-updater/` | Scripting App 版 iOS 更新器（检查 Release、写入 Rime 目录、URL scheme 部署） |
| `.github/workflows/build.yml` | 推 `v*` tag 或手动触发，构建 macOS DMG / Windows zip / Android APK |
| `app/lib/core/settings_store.dart` | 设置读写（与 Python 版同一路径） |
| `update_desktop.py` | Python 核心：profile 探测、资产选择、下载校验、解包应用、部署、快照/回滚 |
| `backup_userdata.py` | 用户数据备份 / 恢复：个人数据打包 zip，`--restore` 解回用户目录 |
| `gui_app.py` | Python 本地 HTTP 服务与界面 API，调用核心逻辑 |
| `web/` | Python 版界面资源，随服务一起提供 |
| `build_app.py` | 生成 Python 版 macOS `.app` 与 Windows 启动器 |
| `README.md` | 面向使用者的说明 |
| `DESIGN.md` | 设计基准：颜色 / 字体 / 间距 / 圆角 / 组件 / 响应式，改界面前必读 |
| `LICENSE` | GPL-3.0，与方案包一致 |
| `dist/` | 打包产物，已在 `.gitignore`，不要提交 |

Flutter 端关键点：

- `main.dart` 是单页 `HomePage`：设备表（含勾选）、远端版本、进度条、日志、备份列表；
  设置用弹窗，操作前有确认对话框；
- `detectProfiles()`：mac 三条固定路径；Windows 小狼毫取注册表 `RimeUserDir`（退回
  `%APPDATA%\Rime`）、虎韵取 `%LOCALAPPDATA%\Tigrime\Rime`，再扫描 `%APPDATA%` /
  `%LOCALAPPDATA%` 深度 ≤4 找含 `tiger*.schema.yaml` 的目录（跳过已识别目录的子目录与
  `build/`）；
- `applyZip()` 与 Python `apply_zip()` 行为一致：白名单跳过用户数据、`full_required`
  自动改用完整包、快照写 `manifest.json`、超大文件只记录不备份；
- 所有网络请求走 `dart:io HttpClient`，支持 HTTP 代理（**不支持 socks5**，Dart 桌面端限制）；
- `flutter create` 生成的平台目录已按 `com.viui798` 组织，窗口标题与初始尺寸在
  `app/macos/Runner/MainFlutterWindow.swift` 中设置。

脚本内部关键点：

- `detect_profiles()`：mac 三条固定路径 + Windows `%APPDATA%\Rime`，再扫描
  `%APPDATA%` / `%LOCALAPPDATA%` 深度 ≤4 找含 `tiger*.schema.yaml` 的目录（虎韵）；
- `pick_asset()`：先找 `name.endswith("-update.zip")`，没有再退完整包；
- `should_copy()`：白名单式跳过用户数据（`*.userdb`、`*.options.yaml`、`user.yaml`、
  `installation.yaml`、`reverse_freq.txt`、`custom_phrase.txt`、`build/`、`sync/`、
  `lua/kc_count.txt`、`lua/kc_total.txt`、`lua/input_stats_*.lua`、`*.md`）；
- 完整包里 `models/sentence-fivegram-mobile.bin` 同尺寸则跳过；
- `DELTA.json` 的 `full_required` 为真时直接拒绝增量包，提示改用完整包；
- `DELTA.json` 的 `deletions` 只删通过 `should_copy()` 的路径；
- 覆盖已有 `*.custom.yaml` 前备份到 `.cheese-tiger-backup/<时间戳>/`；
- 成功后写 `.cheese-tiger-version`，`--check` 的「当前版本」来自它；
- 下载缓存在 macOS `~/Library/Caches/cheese-tiger`、Windows `%LOCALAPPDATA%\cheese-tiger\cache`，
  默认按 SHA256 复用。

界面层关键点：

- `gui_app.py` 用 `ThreadingHTTPServer` 绑定 `127.0.0.1`，只监听本机；端口被占用时自动顺延；
- 接口：`GET /api/state`、`GET /api/job`、`POST /api/run`（check / update / rollback）、
  `POST /api/settings`、`POST /api/quit`；
- 后台任务由 `Runner` 串行执行，一次只允许一个任务，日志与进度通过 `GET /api/job` 轮询；
- 设置保存在 `~/Library/Application Support/CheeseTigerUpdater/settings.json`
  （Windows 为 `%LOCALAPPDATA%\cheese-tiger\updater-settings.json`），包含 repo、proxy、token、
  cache_dir、deploy、restart、snapshot；
- 增量包返回 `FullPackageRequired` 时，界面会自动改用完整包重试一次；
- 界面默认开启快照，更新后可按时间戳回滚，回滚后同样走部署；
- `build_app.py` 生成 `.app`：`Contents/MacOS/RimeUpdater` 是启动 shell，内嵌 `Resources/app`，
  依赖系统 `python3`（依次尝试 `/usr/bin`、Homebrew 路径），日志写到
  `~/Library/Logs/CheeseTigerUpdater.log`。

## 4. 设计决策

1. **增量包生成器不搬进来**：它依赖方案仓库的 tag 与 Git LFS 状态，属于发版流程；
   本仓库只安装，避免两处维护。
2. **优先增量包而不是完整包**：v0.3.23 完整包 357MB，增量包 791KB；
   大模型变更时生成器会标 `full_required`，客户端自动回退完整包。
3. **白名单跳过用户数据**：宁可少更新一个文件，也不能动 `*.userdb` 与开关记忆。
4. **不写版本号到 `user.yaml`**：用独立 `.cheese-tiger-version`，避免污染 Rime 配置。
5. **部署命令按前端写死**：Squirrel `--reload`、Fcitx5 `fcitx5-curl`、Weasel
   `WeaselServer /q` + `WeaselDeployer /deploy`、虎韵 `Tigrime.Deployer.exe`（无参数即完整
   部署，自带停/起服务）；元书没有 CLI 部署接口，只能提示或重启。
6. **只用标准库**：用户机器不一定有 pip 环境；代理通过 `urllib` ProxyHandler 支持。
7. **不做自动升级自身**：脚本从仓库直接运行时没有可靠的自我替换路径，先保持手动。
8. **主界面改用 Flutter**：一套 Dart 代码同时覆盖 macOS / Windows（后续 Android / iOS），
   是真正的原生窗口而不是浏览器页面；Python 版 Web 界面保留为备用。
9. **快照上限 32MB**：模型文件太大，全部快照会让磁盘翻倍；超大文件只记录、不复制，
   回滚时明确提示无法恢复。
10. **任务串行**：同一时刻只允许一个更新 / 回滚任务，避免两个进程同时写同一目录。
11. **设置文件两个客户端共用**：Flutter 与 Python 都读写
    `~/Library/Application Support/CheeseTigerUpdater/settings.json`
    （Windows 为 `%LOCALAPPDATA%\cheese-tiger\updater-settings.json`），切换客户端不用重配。
12. **云同步用「共用文件库」而不是整包 zip**：云端按前端存
    `CheeseTigerSync/<kind>/files/<相对路径>`，`manifest.json` 记录每个文件的来源设备与时间。
    好处是可以只上传 / 删除单个文件，不用为了改一个文件重传整包；也不用依赖 WebDAV 的
    PROPFIND。代价是文件多时请求数多（个人数据通常十几到几十个，可接受）。
    批量上传仍以 `collectUserData` 白名单为默认，避免把模型和方案文件传上去。

## 5. 验证清单（改代码后必跑）

Flutter 客户端：

```bash
cd app
dart analyze                      # 静态分析
flutter test                      # 过滤规则 / 解包 / 快照回滚 / 同步 / 界面，当前 37 项
dart run tool/verify.dart         # 真实下载（走缓存）+ 对首个目录预演，不需要打开界面

# Xcode 未设为默认时：
DEVELOPER_DIR=/Applications/Xcode-16.2.0.app/Contents/Developer flutter build macos
# 产物：build/macos/Build/Products/Release/RimeUpdater.app

# Windows（在 Windows 机器上，需要 VS「使用 C++ 的桌面开发」）：
flutter pub get
flutter build windows --release
# 产物：build\windows\x64\runner\Release\rime_updater.exe（整个 Release 目录一起分发）

# Android（JDK 17 + Android SDK 36）：
export JAVA_HOME="$HOME/android/jdk17/Contents/Home"
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
flutter build apk --debug
# 产物：build/app/outputs/flutter-apk/app-debug.apk

# 本机 Windows 开发环境（2026-11-04）：
#   Flutter 3.47.9 / Dart 3.13.7 在 C:\Users\23038\dev\flutter（用户 PATH 已加入）
#   国内镜像：FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
#             PUB_HOSTED_URL=https://pub.flutter-io.cn
#   VS BuildTools 2022 17.14（C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools）
#   注：在 agent 的非交互 shell 里 flutter.bat 会卡住，可直接调用
#   %FLUTTER_ROOT%\bin\cache\dart-sdk\bin\dart.exe 加 flutter_tools.snapshot 执行同名命令
```

Python 侧（改脚本时）：

```bash
python3 -m py_compile update_desktop.py gui_app.py

# 1) 识别与远端（不需要 token）
python3 update_desktop.py --check

# 2) 远端增量包全流程预演
python3 update_desktop.py --dry-run --yes

# 3) 本地包预演（带 sha256 旁文件时自动校验）
python3 update_desktop.py --source ~/Desktop/输入法/芝士虎整/cheese-tiger-v0.3.23-update.zip --dry-run --yes

# 4) 单目录验证，避免动真实用户目录
python3 update_desktop.py --target /tmp/rime-test --dry-run --yes

# 5) 备用界面
python3 gui_app.py --port 8766 --no-browser &
curl -s http://127.0.0.1:8766/api/state
```

真实更新前建议先「仅预演」；部署会不会打断输入取决于前端，元书/小企鹅可勾选“重启前端”。
回滚逻辑验证时，用临时目录构造旧文件 + 快照，确认 `manifest.json` 与实际还原一致。

## 6. 已完成的工作记录

1. 初版：识别 mac 三前端 + Windows 小狼毫/虎韵扫描，增量包优先，SHA256 校验，用户数据跳过。
2. 在 mac 三前端实机跑通 v0.3.23 增量更新（8 文件 / 791,261 字节 / SHA `eed96f3b…`）。
3. 方案仓库发布 v0.3.23 时上传 `cheese-tiger-v0.3.23-update.zip` + `.sha256`，客户端确认优先选中。
4. 修复：增量包曾误含 `docs/`、`tools/`（目录前缀匹配写法错误）；完整包 `DELTA.json` 探测错误；
   `full_required` 检查顺序（应在复制前）。
5. 仓库独立：从方案仓库 `tools/` 移出，方案仓库只保留增量包生成器并更新 AGENTS/文档。
6. 更正：方案仓库实际是公开的，token 说明改为「仅避开限流」，匿名实测通过。
7. 图形界面：新增 `gui_app.py` + `web/`，本地 Web UI 覆盖检查、更新、预演、设置、日志、
   进度、回滚；浏览器实测三前端卡片与设置弹窗正常，控制台无报错。
8. 回滚能力：`apply_zip` 支持完整快照（`manifest.json` 记录覆盖/新增/删除），
   新增 `list_backups()`、`rollback()` 与 `--snapshot` / `--rollback`；
   临时目录实测 8 文件覆盖后全部还原，版本标记正确回退。
9. 打包：`build_app.py` 生成 `dist/RimeUpdater.app`，双击启动服务并打开浏览器，已实测
   `/api/state` 返回 200、`/api/quit` 可正常退出。
10. 用户数据备份：`backup_userdata.py` 收集自造词、调频、选项、自学习、统计、击键、
   主题与 `*.userdb`，按前端各打一个 zip（含 `BACKUP.json`），`--restore` 可解回；
    鼠须管实测 16 项 / 207KB，备份与恢复后文件逐字节一致。未改任何运行时路径。
11. Flutter 客户端：新建 `app/`（`flutter create` 生成 macos / windows / android / ios
   平台目录），用 Dart 重写探测、Release 下载、SHA256、增量包解包（`archive`）、快照回滚、
   部署与设置；Material 3 单窗口界面，含设备勾选、进度、日志、备份回滚。
    `dart analyze` 无问题，`flutter test` 9 项通过（含真实 zip 的解包与回滚往返验证）。
12. 环境记录：Homebrew 安装 Flutter 3.47.9；通过 Xcodes.app 安装 Xcode 16.2
    （`/Applications/Xcode-16.2.0.app`，App Store 最新版要求 macOS 26.6，本机 14.8.7 装不了）。
13. 首次启动修复：发现 Flutter 模板默认 App Sandbox 导致「识别不到 Rime 目录 + 网络不可用」，
    移除两个 entitlements 的 `app-sandbox` 后重新构建，实跑确认三前端、远端版本、预演 8 文件正常。
14. 应用图标：用 AI 生成老虎头像，去除生成水印后切 16–1024 各尺寸替换
    `AppIcon.appiconset`，并生成 `windows/runner/resources/app_icon.ico`；DMG 用
    `tool/make_dmg.sh`（内含「应用程序」软链接），实测挂载与校验通过。
15. Windows 打包：`windows/runner/main.cpp` 设置中文窗口标题与 1000×760 初始尺寸；
    新增 `.github/workflows/build.yml`，tag 推送时在 windows-latest 构建 zip、
    在 macos-latest 构建 DMG，并自动创建 Release。
16. 任意方案支持：`从本地 zip 安装`（系统文件选择框 + 版本推断 + 扁平/带目录 zip 前缀识别），
    以及 `换方案向导`（备份个人数据 → 清理旧运行文件 → 安装 → 恢复 → 部署），
    单元测试覆盖备份收集、清理保留用户数据、lua 统计恢复。
17. 手动添加目录：设备区右上角「+」调用系统目录选择框，目录写进设置 `custom_dirs`，
    下次启动仍然生效；不符合 Rime 特征时先弹确认。
18. 可拖动布局：设备 / 日志 / 备份三块之间加分隔条，拖动调整高度（日志区保持最小 120），
    双击分隔条恢复默认值；测试覆盖拖动不报错。（UI v2 已移除该交互，见第 28 条）
19. 体验补充：手动设备可改名（`custom_names`）；检查日志标注「（最新）/（可更新）」；
    内容与包内一致的文件直接跳过，不再重复写盘与生成快照；备份区增加「清理备份」。
20. 任意 GitHub 方案：主界面「GitHub 方案」填入 owner/repo 或仓库网址，读取最近 Release
    的 zip 资产（优先 `-update.zip`），下载后按本地包同一套逻辑安装；用雾凇拼音
    `full.zip` 预演验证：识别 68 个文件、用户数据跳过。日志中的状态后缀用绿/橙着色。
21. 云同步（WebDAV）：新增 `WebDavClient`（MKCOL / PUT / GET / DELETE + Basic Auth，
    路径逐段编码以支持中文文件名）、`sync_service.dart`（共用同步库清单、批量/单个上传、
    删除、下载、设备 ID 持久化）、`sync_dialog.dart`（配置 + 文件管理 + 上传/下载）；
    设置新增 `sync_url` / `sync_user` / `sync_password` / `device_name`，
    主界面远端行新增「云同步」。
    `flutter test` 30 项通过：测试从 zip 改为真实 HTTP 往返（本地 HttpServer 模拟
    WebDAV，覆盖 MKCOL/PUT/GET/DELETE、中文文件名、`*.userdb` 目录展开、删除后清单更新、
    下载覆盖前备份），另有清单解析、设置字段、弹窗渲染；重建 macOS App 与 DMG。
22. 同步库文件管理器：新增 `SyncLibraryDialog`，文件夹式浏览同步库、根层按端分组、
   上传单个文件、在线编辑文本（`readCloudFile` / `writeCloudFile`）、删除（含
   `*.userdb` 整组）；`sync_service` 增加 `listEntries` / `readCloudFile` / `writeCloudFile`；
   主界面新增「同步库」按钮。测试增至 32 项（新增文件树分组、编辑回写、弹窗渲染），
   实跑确认远端行 5 个按钮无溢出。
23. 联网时机优化：移除启动 400ms 后自动 `_check()`，打开 App 不再消耗 GitHub 匿名额度；
   检查成功后缓存 `ReleaseInfo` 10 分钟，`preparePackage` 增加可选 `release` 参数复用结果，
   避免「检查 + 更新」重复请求；`flutter test` 32 项通过（首页测试断言启动时日志为空）。
24. Android 端：同一套 Dart 逻辑接入 Android，
   - `detectProfiles` 增加 `/storage/emulated/0/rime`（Trime 默认）与旧版路径；
   - 设置 / 缓存路径按 Android 应用私有目录适配；部署改为提示在 Trime 内刷新；
   - 新增 `android_platform.dart` + `MainActivity.kt` MethodChannel：所有文件访问权限、
     系统文件选择（选中 zip 复制到 cache）；Manifest 增加 INTERNET / MANAGE_EXTERNAL_STORAGE、
     中文应用名、允许明文 HTTP（局域网 WebDAV）；
   - 主界面窄屏改为可滚动单页：状态条 + 三个等宽主按钮 + 云同步/同步库/更多菜单，
     设备、日志、备份卡片按内容高度排列，不再有拖动分隔条与大片空白；全部弹窗宽度自适应；
   - 用模拟器（API 35）验证：启动、授权、识别 Trime、检查更新 v0.3.23、预演 8 文件、
     正式更新 8 文件 + 快照 + 回滚记录；`app-release.apk` 52.8MB；
   - Actions 增加 android job，产出 `android-apk` artifact。测试增至 33 项（新增窄屏布局）。
25. Windows 实机接入（2026-11-04）：本机 Windows 开发环境搭建（Flutter 3.47.9 + VS
   BuildTools 2022 C++ 工作负载，国内镜像）；修正识别逻辑——小狼毫读注册表
   `HKCU\Software\Rime\Weasel\RimeUserDir`，虎韵读自己的 `%LOCALAPPDATA%\Tigrime\Rime`
   （两者用户目录不同，之前会把虎韵误判成小狼毫）；新增虎韵部署
   `Tigrime.Deployer.exe`（实测无参数调用约 26 秒，输出
   `{"deployed":true,"server_resumed":true}`；`--ensure` 只检查不重建）；部署改为异步
   `Process.run` 避免 26 秒卡住界面；`dart analyze` 无问题、`flutter test` 33 项通过、
   `flutter build windows --release` 成功，实机识别出「小狼毫」与「虎韵」两个设备
26. 设备删除（2026-11-04）：设备行末尾「⋮」→「删除设备」；自动识别的目录写入设置
   `hidden_dirs`，`detectProfiles(hidden:)` 跳过；手动目录删除只清 `custom_dirs` /
   `custom_names`；再次手动添加会自动解除隐藏。实机截图确认三行都有「⋮」，
   隐藏 Weasel-RS 目录后识别数 3 → 2；`flutter test` 33 项通过
27. iOS Scripting 脚本：新增 `ios/scripting/cheese-tiger-updater/`（script.json + index.tsx +
   utils），检查芝士虎整 Release、优先增量包、去掉 `update/` 前缀、跳过个人数据、
   覆盖前备份到 `.cheese-tiger-backup`，安装后用 `hamster://` / `hamster3://` 请求部署；
   文件与下载工具改编自 `BlackCCCat/Scripting-Scripts`（MIT，README 已注明）。
   esbuild 语法检查通过；**未在 iOS 真机 / Scripting App 验证**；不执行 DELTA 删除列表。
28. iOS 全功能对齐（2026-11-04，脚本 1.1.0）：
   - 仅预演：`planZip` 解压到临时目录逐个比对，输出「将更新 / 新增 / 跳过个人数据」
     数量与前 20 个文件名，不写盘；
   - 任意 GitHub 方案：`fetchLatest(token, repo, assetName)`，设置页可改 `owner/repo`
     或网址，检查后列出 zip 资产可「选用」；
   - 快照升级：`installZip` 写 `manifest.json`（版本 / 覆盖 / 新增），回滚时先删
     快照里「新增」的文件再写回备份，与桌面端语义一致；设置页可回滚 / 删除 / 刷新；
   - 本地 zip：`DocumentPicker.pickFiles` + `stageLocalZip`（先拷到临时目录），
     文件名推断版本；
   - 换方案向导 `utils/switch_scheme.ts`：收集个人数据 → 备份到
     `<Rime>/.cheese-tiger-backup/switch-<时间戳>/` → 清理 `lua/opencc/models/dicts` 等
     与根目录非个人 yaml → 安装 → 只补回缺失的个人数据 → 部署；支持本地 zip 与仓库包；
   - 新增「清空日志」；esbuild 语法检查通过；**未真机验证**
29. iOS 云同步与布局重构（2026-11-04，脚本 1.2.0）：
   - 参考用户自备的 SyncClipboard 脚本，确认 Scripting `fetch` 的 `body` 支持
     `Data`/`ArrayBuffer`、`Response.data()` 可直接落盘（官方文档 scriptingapp.github.io）；
   - 新增 `utils/webdav.ts`（MKCOL/PUT/GET/DELETE + Basic Auth，路径逐段编码，
     中文文件名可用）与 `utils/sync_service.ts`（`CheeseTigerSync/<kind>/files/` +
     `manifest.json`，上传/下载/删除、`*.userdb` 目录展开）；
   - 界面从三页 TabView 改成与参考脚本一致的单页 List：目录、更新、云同步
     （TextField/SecureField 配置）、备份回滚、换方案、更新来源、设置、日志；
     密码存 Keychain；
   - esbuild 语法检查通过；**未真机验证**（重点：坚果云 MKCOL/PUT 中文路径、
     `.userdb` 二进制上传、下载覆盖前备份）
30. UI 视觉系统（2026-11-04）：参考 awesome-design-md 的 DESIGN.md 范式新增根目录
   `DESIGN.md`（暖纸画布 + 虎琥珀单强调色、发丝线卡片、pill 主按钮、eyebrow 小节标签、
   等宽日志），落地为 `app/lib/ui/app_theme.dart` 的全局 ThemeData（亮 / 暗两套）；
   重做顶栏、远端信息条、设备行、日志面板、备份行（随后被 31 的 v2 取代）
31. 品牌与 UI v2「冷霜」（2026-11-04）：脱离芝士虎整品牌，改名「Rime 更新器 /
   RIME UPDATER」，窗口标题与 Android 应用名同步；新图标为几何 R + 更新环（冰蓝 × 墨黑），
   由 `icon_master.html` 渲染母版后导出 Windows `.ico`（16–256，PNG 条目）、Android
   mipmap（48/72/96/144/192）、macOS AppIcon（16–1024，20% 留白）；
   `DESIGN.md` 重写为 v2（冷霜 token、深色控制台、眉标英文大写）；
   桌面改为「顶栏 + 远端版本卡（大号版本 + 设备/可更新/备份统计 + 进度 +
   TOOLS 工具条：云同步/同步库/GitHub 方案/换方案/本地 zip）+ 左侧设备/备份、
   右侧深色控制台」，移除拖动分隔条；手机改为单页滚动并整行主按钮；设备行改自绘勾选框；
   `dart analyze` 无问题、`flutter test` 33 项通过；Windows release 构建成功，
   实机截图验证 1000×760 与 420×800 两套布局

32. UI v3「静序」（2026-11-04）：按用户要求重新阅读 `VoltAgent/awesome-design-md`
   的 Linear / Raycast 设计分析，落地雾白 + 淡紫主题、180px 桌面侧栏（方案管理 / 个人数据）、
   版本卡片内集中更新 / 检查 / 预演、设备与备份 + 日志双栏；中文主标题、英文次级标记，
   主按钮改 8px 圆角，去掉嵌套黑色日志内框。手机与低矮窗口主体整体滚动，设备状态 / 版本
   换行，增加选中语义；同步等弹窗沿用全局主题。macOS 标题栏与应用名统一「Rime 更新器」，
   最小窗口 360×500，支持手动缩窄预览。`DESIGN.md` 更新为 v3 并记录参考来源。
   `dart analyze` 无问题，`flutter test` 37 项通过（新增 320×640 / 960×600 / 1000×540 /
   1440×900、深色 + 1.2 倍文字、更多菜单与侧栏入口交互验证）；`tool/verify.dart` 真实下载
   v0.3.24、SHA256 通过、仅预演 0 更新 / 7 跳过，未改 Rime 文件。macOS release 构建与
   实际窗口 / 设置弹窗查看通过。首次构建缺失 FlutterFramework.swift，`flutter clean` +
   `flutter pub get` 重建生成文件后恢复；不是业务代码问题。启动不联网、缓存、快照、部署与
   用户数据过滤逻辑保持不变；尚未重新构建或实跑 Windows / Android。

33. 手机端与 Android 安装包（2026-11-04）：窄屏主操作改为并排「检查更新 / 仅预演」+
   下方整行「一键更新」，按钮最小高 48，繁忙时禁用「更多功能」，保持单页整体滚动。
   `dart analyze` 无问题、`flutter test` 37 项通过，`tool/verify.dart` 只读预演通过。
   `flutter build apk --release` 成功，通用 APK 52.8MB（arm64-v8a / armeabi-v7a / x86_64），
   沿用项目现有 debug key 签名，APK v2 签名校验通过；Android 15 / API 35 模拟器覆盖安装、
   冷启动成功，截图确认新主题、整行主按钮、同文目录识别与空日志正常，没有执行真实更新。
   交付 `dist/RimeUpdater-v1.0.0-ui-v3-android.apk` 及 `.sha256`，截图同目录；全部被忽略不提交。
   构建环境注意：macOS 使用 `LANG/LC_ALL/LC_CTYPE=en_US.UTF-8`，`JAVA_HOME` 见第 5 节，
   `ANDROID_HOME` / `ANDROID_SDK_ROOT` 都指向 `/opt/homebrew/share/android-commandlinetools`，
   `GRADLE_OPTS=-Dorg.gradle.daemon=false` 避免复用旧 locale daemon。不要同时运行没有相同
   SDK 环境的 Flutter 命令，它可能把 `android/local.properties` 重写到仅有 adb 的 Homebrew
   platform-tools 目录，引发误报缺 SDK / license；无需重新接受许可或重装 SDK。未在 Android
   真机验证，此次未构建 iOS / Windows，也未重新打 macOS 包。

34. 安装到本机（2026-11-04）：按用户要求将 v3 release APK 覆盖安装到 Android API 35
   模拟器 `emulator-5554`，SHA256 验证成功，安装返回 Success，冷启动后确认应用为前台
   resumed activity；未执行方案更新。macOS 从当前源码重新 release 构建成功，将应用安装到
   `/Applications/RimeUpdater.app`，安装前旧应用保存到
   `dist/install-backups/20261104-235652/RimeUpdater.app`，源 / 安装目录 28 个文件及符号链接
   校验一致，`codesign --verify --deep --strict` 通过。实际从 Applications 启动，确认窗口
   「Rime 更新器」、v3 侧栏与三个前端识别正常、启动日志为空。未改个人设置或 Rime 文件。

35. iOS 排版重构（2026-11-04，脚本 1.3.0）：应用户「排版不清晰」反馈，把单页 List
   （9 个 Section、20+ 按钮、约 15 屏）改成「主页 + 子页面」：主页保留状态卡
   （目录 / 已装 / 远端 / 状态 / 下载进度条 / 更新说明摘要）、更新按钮（一键更新
   prominent + 检查 / 预演、本地 zip / 部署）、目录行（每行「⋮」Menu：设为当前 / 重命名 /
   安装到此目录 / 部署方式三选 / 移除，「＋ 添加目录」也收进 Menu）与「更多」区
   NavigationLink；云同步、备份与回滚、换方案、设置、日志拆成 5 个子页面
   （新文件 `ui/pages.tsx`，纯展示组件，状态与回调全部由主页 props 传入）；
   云同步文件列表取消 40 条上限并按 `*.userdb` 合并成组（与桌面端一致）；
   资产选择从「选用」按钮行改成 Picker（menu 样式）。编排逻辑基本不动：仅 `install`
   拆成 `installTargets` + `installAll` / `installToDir`、`removeCloudFile` 改为批量
   `removeCloudFiles`、三态循环的 `cycleMethod` 改为直接选定的 `setMethod`；配置类型与
   读写迁到新文件 `utils/config.ts`。组件写法均经官方文档核对（NavigationLink
   destination、Menu、Picker、ProgressView、buttonStyle）。esbuild bundle 检查通过；
   **未真机验证**（若推入的子页面状态不随操作刷新，回退方案是把对应操作按钮挪回主页）。
36. Windows 对齐 v3（2026-11-05）：v3 是共享 Flutter 代码，Windows 直接获得静序视觉；
   平台层补齐：窗口初始尺寸 980×760（与 macOS 一致）、`WM_GETMINMAXINFO` 最小 360×500
   （按 DPI 缩放）；等宽字体在 Windows 上原本回退成非等宽，给所有 `Menlo` 增加
   `fontFamilyFallback: ['Consolas', 'monospace', 'Courier New']`（macOS / Android 同时受益）；
   `dart analyze` 无问题、`flutter test` 37 项通过；`flutter build windows --release` 成功并
   覆盖安装，实机截图验证 980×760 与 420×800 布局
37. 卸载残留修复（2026-11-05）：安装包卸载后残留空文件夹，排查到 `WeaselServer.exe`
   占用安装目录——更新器部署后重启小狼毫时，服务继承了更新器的当前工作目录。
   `_deployWeasel` 现在以 Weasel 安装目录作为 `workingDirectory` 启动服务；
   安装包补 `[UninstallDelete] {app}\data` 与 `usPostUninstall` 的 `RemoveDir`。
   实测「安装 → 启动 → 卸载」后目录与注册表均清空，重装后再启动正常
38. 发布物与架构（2026-11-05）：`dist/` 产出 `RimeUpdater-v1.0.0-Setup.exe`（Inno，用户级
   安装）与 `RimeUpdater-v1.0.0-portable-x64.zip`（免安装，含 `使用说明.txt`）；两者都由
   `app/windows/installer.iss` 与 `app/build/windows/x64/runner/Release` 生成。
   Flutter 3.47 的 Windows 桌面端只有 x64 引擎产物（`bin/cache/artifacts/engine` 里只有
   `windows-x64*`，`build windows` 也没有 `--target-platform`），因此无法产出 arm64 原生包，
   也不支持 32 位；Windows on ARM 直接用 x64 包（系统自带 x64 模拟）。

36. Android 包体积排查（2026-11-05）：只读拆解现有 release 通用 APK（52,825,378 bytes）。
   原生库占 52.31MB / 99.02%：arm64 17.73MB、armeabi-v7a 15.34MB、x86_64 19.24MB；
   三套 Flutter 引擎合计 33.46MB，Dart AOT（含使用的框架代码）18.84MB。6 个 .so 均未压缩，
   其余资源与包结构约 0.52MB，没有把 Rime 方案 / 模型打进去。建议以后直接分发用
   `flutter build apk --release --split-per-abi`，arm64 包预计约 18MB（未重打包，属估算）。
   完整条目测量与说明在 `dist/android-apk-size-report.md`；本次未改构建配置、未重装应用。

37. 按 CPU 架构打包（2026-11-05）：按用户要求执行 `flutter build apk --release
   --split-per-abi`，生成 arm64-v8a 18.21MB、armeabi-v7a 15.82MB、x86_64 19.71MB 三个
   独立 APK；相较原 52.83MB 通用包分别减少 65.5% / 70.1% / 62.7%。产物复制到 `dist/`，
   文件名为 `RimeUpdater-v1.0.0-ui-v3-android-<abi>.apk`，每包附 `.apk.sha256`，另有
   `RimeUpdater-v1.0.0-ui-v3-android-split-manifest.json` 记录体积、版本代码与 SHA256。
   已验证 ZIP 完整性、每包仅含对应架构的 libflutter.so / libapp.so、应用 ID、APK 签名
   有效且与原通用包证书相同（沿用项目测试签名）。Flutter 分包 versionCode 自动变为
   ARM32 1001 / ARM64 2001 / x86_64 4001；今后覆盖升级需注意版本代码不能降低。
   本次仅构建和校验，未改源码、未覆盖安装；原通用包保留。实测结果追加到体积分析报告。

38. Android 真机安装（2026-11-05）：通过无线 ADB 给用户手机（23127PN0CC / houji，
   ARM64）安装 `RimeUpdater-v1.0.0-ui-v3-android-arm64-v8a.apk`（18.21MB），
   安装前 SHA256 与清单一致，`adb install -r` 返回 Success；启动 MainActivity 成功，
   进程存在且主界面为前台 Activity。仅验证安装与启动，权限、目录识别及更新由用户实测。

39. Android 多前端与 Shizuku 接入（2026-11-05）：
   - 原版仅识别两个固定同文路径。新增公共存储中输入法命名目录的有限扫描（不遍历全盘）、
     任意 `*.schema.yaml` / `default.yaml` 特征识别、Android 手动公共路径、授权返回刷新。
   - 新增设备区盾牌入口，通过官方 Shizuku API 13.1.5 授权和绑定 UserService；
     枚举已安装 Rime 输入法，探测 `Android/data/<pkg>/files/{rime,data/rime,...}`。
     Shizuku 的 shell 身份仍不可读 `/data/user/0`，未找到目录的前端在访问说明里列出，
     不伪装成可更新；内部目录需要输入法自己的公共目录 / 导入导出功能。
   - 新增 `android_profiles.dart`、`ShizukuBridge.kt`、`RimeFileService.kt`、`IRimeFiles.aidl`：
     通过 PFD 流式读取到缓存（跳过根 build），原 Dart 安装 / 换方案 / 回滚 / 批量同步逻辑
     在暂存区工作；只提交变化文件，SHA256 前置检查，备份后写入，失败恢复，恢复失败或
     崩溃遗留事务保留 `.rime-updater-txn-*` 并阻止继续提交；不执行任意 shell 命令。
     大目录会占用暂存空间；系统单文件选择器仍不能浏览受限目录，优先批量同步。
   - `dart analyze` 无问题；Flutter 40 项通过；`dart run tool/verify.dart` 真实 v0.3.24
     校验与只读预演通过。5 项 Android 原生测试在真机独立 `.dev` 应用的临时目录通过：
     读取 / 提交增改删与备份 / 冲突拒绝 / 中途失败恢复 / 越界拒绝。测试应用已卸载。
     模拟器存储不足拒绝安装，故改用隔离测试应用；debug 现在用 `.dev` 后缀，避免覆盖 release。
   - 新版三 ABI APK 在 `dist/RimeUpdater-v1.0.0-build2-shizuku-android-<abi>.apk`：
     ARM64 18,877,540 bytes、ARM32 16,722,876、x86_64 20,319,858，附 SHA256 与 JSON 清单。
     `pubspec` build number 升至 2（ARM64 versionCode 2002），签名仍沿用项目测试证书。
   - ARM64 已覆盖安装到用户手机并启动，用户亲自允许 Shizuku；实机截图确认 5 目录：
     公共 `rime`、`咩文rime文件夹`、`rime-cheese`，以及 Shizuku 同文、
     中州鹅（`org.fcitx.fcitx5.android.fx.rime/files/data/rime`）。正式方案更新和
     真实受限目录的写回由用户后续实测，本次未操作；安装 / 识别与隔离文件测试已验证。
     验证记录和截图在 `dist/android-shizuku-validation/`。

40. macOS 更新后小企鹅 / 元书打不了字（2026-11-05）：根因是**增量包只带「相邻 tag 之间
   变化的文件」，补不上老底子缺的新增文件**。小企鹅（`~/.local/share/fcitx5/rime`）与
   元书（`~/Library/Application Support/com.ihsiao.inputmethod.Cobra/RimeUserData`）是
   旧版完整包装的，版本标记虽走到 0.3.23/0.3.24，但文件基线停在旧世代——`yin_full.lua`、
   `tiger_full.dict.yaml`、`tiger_sentence_dispatch.lua`、`input_statistics_proc.lua` 等
   后续新增的文件从未被任何增量包带到。v0.3.24 改了 `tiger_sentence.schema.yaml`
   （新 schema 唯一翻译入口是 `lua_translator@tiger_sentence_dispatch`，并引用
   `*yin_full` 与 `tiger_full` 词典），缺文件导致 Lua 栈 / 部署失败 → 出不了字；
   鼠须管目录是较新完整包装、文件齐全，不受影响。修复：从 `~/Library/Rime` 复制 8 个
   缺失文件（上述 4 个 + input_stats_*.lua×4；root 下的同名 lua 是旧副本不用抄，
   `english_chinese.txt`、`wanxiang_pro*`、`dicts/`、`zuci/` 属其他方案 / 个人文件不抄），
   fcitx5 用 `fcitx5-curl /config/addon/rime/deploy`（实测该端点只写配置值不触发部署，
   真正部署要按 Control+Alt+grave 或切到小企鹅时自动维护）、元书 `killall Cobra`
   重启等激活时部署。**教训**：方案仓库 `make_release_delta.py` 应改为「相对最老支持基线
   生成增量」或在 DELTA.json 里带必需文件清单（缺失即回退完整包），否则旧基线用户每次
   方案新增文件都会踩同一坑。`build/kf.*.bin` 是 v0.3.24 移除 kf 后的残留，无害。

41. 补充 Android 前端路径（2026-11-05，build 3）：按用户提供路径接入中文输入法
   `/sdcard/Android/rime`（统一使用 `/storage/emulated/0/Android/rime`）、小狐狸
   `Android/data/com.fxliang.foxy/files/foxy/rime`、中文输入法2 / 元书共用的 `Documents/rime`。
   实机发现后两处都是多方案容器，新增受限目录 `discoverRoots` 与公共目录 `schemas/`
   子目录识别，只将含 Rime 配置的实际方案目录列为目标，不把包写到容器根目录；排除
   conf/build/themes 等目录，共用路径去重。小狐狸包可见性与已安装前端筛选同步补齐。
   - Flutter 41 项通过；静态分析无问题；6 项真机隔离原生测试通过，新增多方案扫描测试。
     临时 `.dev` / `.dev.test` 应用已清理，未修改任何真实输入法方案。
   - 三 ABI release + SHA256 清单在 `dist/RimeUpdater-v1.0.0-build3-android-<abi>.apk`，
     ARM64 18,877,568 bytes，已校验 v2 签名并覆盖安装到用户手机（versionCode 2003）。
     Shizuku 既有授权保留，启动截图确认识别数 5 → 11：原 5 处 + 中文输入法 1 处 +
     中文输入法2 / 元书共用 schemas 的 2 个方案 + 小狐狸万象九键 / 九键虎 / 虎整句 3 个方案。
     截图为 `dist/android-shizuku-validation/phone-build3*.png`；正式更新仍由用户实测。

42. README 全面重写（2026-11-05）：按 `ccch1mneyyy/dsh-Go` 的展示顺序，采用居中图标 /
   简介 / 徽章、功能展示、下载入口、完整功能、安装与权限、折叠 FAQ、CLI、构建、目录、贡献
   与许可致谢。核对当前 Flutter / Android Shizuku / iOS Scripting / Python 的功能差异，
   写明多目录、预演、增量回退、GitHub / 本地 ZIP、换方案、数据保护、快照、WebDAV 与在线编辑。
   - 从已有 build 3 真机截图裁掉系统栏并缩小，保存到 `docs/assets/android-home.png` 与
     `android-shizuku.png`，作为可随仓库分发的 README 图片；未新增截图采集或操作用户方案。
   - 更正旧 README 的 Android 未接入、Python 功能完全一致、完整快照等过时 / 绝对描述；
     明确 32 MiB 限制、普通 Shizuku 无法访问内部私有目录、凭据明文存储、iOS 未真机验证、
     真实受限目录写回待验证，以及旧基线增量可能缺文件的问题。CI 通用包与本地分 ABI 包分开说明。
   - 本次仅文档与展示图片变更；检查本地链接、锚点、HTML 标签、代码围栏和 `git diff --check`，
     未重跑应用测试 / 构建。README 的 41 项 Flutter + 6 项原生结果引用上一轮验证记录。

43. v1.0.0 发版（2026-11-05）：合并分叉后统一收口——本地提交了 Shizuku / 多前端成果
   （39b70aa），与远端 Windows 对齐 + 基座校验两提交做 merge（README 冲突保留新版徽章
   结构并把 Windows 安装版 / x64 要求并入「安装」章节）；合并后 `dart analyze` 无问题、
   `flutter test` 42 项全部通过。发版准备：`pubspec` 升 1.0.0+4（Android versionCode
   链路保持单调）；`build.yml` Android job 增加分架构 APK（`--split-per-abi`，约 18MB），
   Windows job 用 choco innosetup 跑 `installer.iss` 产出 Setup.exe 并随 artifact 上传，
   Release 说明整体重写为 v1.0.0 功能与安装说明（旧文案还是「芝士虎整」品牌且只提 Trime）。
   推 main 后打 `v1.0.0` tag 触发三平台构建并自动建 Release。

## 7. 下一步（按优先级）

1. **Windows 回滚实跑**：识别、更新与部署已在实机验证（两设备 0.3.1/0.3.2 → 0.3.23，
   快照与部署均成功）；还差从「备份与回滚」点一次回滚并确认部署后候选正常。
2. **界面实跑更新**：macOS 目前只做了「检查 + 预演」；等有真实新版本时跑一次完整更新与回滚。
3. **云同步实机验证**：用真实 WebDAV 账号（坚果云 / Nextcloud）跑一遍「上传本机 →
   另一台设备下载云端」，确认目录创建、清单读写、单个文件增删与覆盖前备份都正常；
   若服务端返回 301/409，需要在 `webdav_client.dart` 里补处理。
4. **Android 真机验证**：模拟器（API 35）已验证启动、权限授予、识别 `/storage/emulated/0/rime`、
   检查更新、预演与正式更新；真机还需确认 MANAGE_EXTERNAL_STORAGE 授权流程、
   Trime 实际目录（可能被用户改过）以及更新后在 Trime 里刷新部署的体验。
5. **iOS Scripting 脚本验证**：在 iPhone / iPad 的 Scripting App 里导入
   `ios/scripting/cheese-tiger-updater`，用仓输入法（`文件/Hamster/Rime`）与元书实际跑
   检查 / 预演 / 安装 / 回滚 / 本地 zip / 换方案；若 Scripting API 有差异，按真机报错调整
   `utils/`。**待补**：云同步（WebDAV）与同步库管理，需先确认 Scripting `fetch` 能否
   用 `Data` 上传二进制（`.userdb`），确认后复用桌面端 `CheeseTigerSync/<kind>/files/` 结构。
6. **界面增强**：显示落后版本数；失败自动重试；把 `backup_userdata.py` 的备份/恢复
   用 Dart 重做并接进界面。
7. **体验**：Dart 桌面端不支持 socks5，只支持 HTTP 代理；可引入第三方包补 socks5。
8. **签名与图标**：Flutter 版应用图标已完成，但仍未签名；分发需要配置 macOS 签名与公证。
9. **可选**：执行一次
   `sudo xcode-select --switch /Applications/Xcode-16.2.0.app/Contents/Developer`，
   之后构建不用再带 `DEVELOPER_DIR`。

## 8. 提交规范

- 中文提交信息，说明「为什么」，不要只写「更新脚本」；
- 改脚本必须跑第 5 节清单，并在提交信息里写验证结果；
- 不提交 `__pycache__`、下载缓存、任何用户目录内容。

## 9. 交接快照（每次会话结束更新这一节）

> 2026-11-05 · `main` · 本次：参考 dsh-Go 重写 README，完整梳理各端功能与使用边界

- **本次文档交付**：README 已重写，覆盖 Flutter 桌面 / Android、Shizuku、多方案目录、
  WebDAV 同步库、iOS Scripting 与 Python CLI / 备份工具。附两张裁剪缩小后的真实 Android
  截图（`docs/assets/`）；文档链接、锚点、HTML / 代码围栏及 diff 空白检查通过。
  本次没有修改客户端实现、安装软件、执行方案写入或重新构建；现有未提交功能改动保持。
  最新应用基线仍为下述 build 3，README 的测试状态引用既有验证结果。

- **最新交付 build 3**：已覆盖安装 ARM64 18.88MB（versionCode 2003），真机识别 11 个
  实际方案目录。新增中文输入法、中文输入法2 / 元书的共用 schemas、小狐狸的三个方案；
  多方案容器不会作为安装目标，共用路径只显示一次。41 项 Flutter + 6 项原生测试通过。
  三架构包和 SHA256 位于 `dist/RimeUpdater-v1.0.0-build3-android-<abi>.apk`，
  `pubspec` 为 1.0.0+3，Shizuku UserService 协议版本为 3。测试应用已卸载。
  正式方案更新、受限目录真实写回与部署仍待用户验证。


- **本次结果**：40 项 Flutter 测试、静态分析、真实下载预演、5 项 Android 隔离文件测试
  全通过。Shizuku ARM64 18.88MB 包已装到用户手机（versionCode 2002），用户已授权，
  实机显示 3 公共目录 + 同文 / 中州鹅两处 Android/data 目录。实际方案更新 / 部署尚未操作。
- **新入口与边界**：设备区盾牌连接 Shizuku，刷新重扫，「+」填写公共目录。
  Shizuku 不代表能访问内部 `/data/user/0`；仓 / 虎标等需按各自数据目录决定使用方式。
  用户期望支持所有前端，仍需逐个验证其内部目录 / 导入导出方式，不能宣称全部已支持。
- **交付**：`dist/RimeUpdater-v1.0.0-build2-shizuku-android-<abi>.apk` 三架构与校验文件。
  `app/pubspec.yaml` 为 1.0.0+2；debug ID 为 `com.viui798.rime_updater.dev`，原生测试目标
  是 `.dev.test`，两个临时测试应用已从手机卸载。release ID 保持原值。
- **后续验证**：真实受限目录的预演、正式写回、回滚与 WebDAV；大目录暂存空间；
  私有目录前端的数据导出接入。遇到 `.rime-updater-txn-*` 遗留先恢复，不要直接再次写回。


- **真机安装**：无线 ADB 安装 ARM64 18.21MB 包到 23127PN0CC，安装成功，已启动并确认
  MainActivity 位于前台；等待用户实测权限、Trime 目录识别与更新流程。

- **本次打包（2026-11-05）**：三个独立 APK 已生成并校验：arm64-v8a 18.21MB、
  armeabi-v7a 15.82MB、x86_64 19.71MB；产物、逐包 SHA256、JSON 清单在 `dist/`。
  ARM64 相比通用包减少 65.5%。未改源码或覆盖设备安装，原通用包保留。
- **包体积报告**：`dist/android-apk-size-report.md` 已追加分架构实际测量结果。

- **已完成并已推送**：Flutter 客户端（`app/`）、GitHub 方案 / 本地 zip / 换方案、
  手动目录与改名、可拖动布局、WebDAV 云同步、文件夹式同步库（上传 / 在线编辑 / 删除）、
  启动不联网与 10 分钟检查缓存、GitHub Actions 三平台构建、Android 端（权限、Trime 目录、
  文件选择、窄屏 UI、Actions android job）
- **本机安装**：最新版已覆盖安装到 Android 模拟器 `emulator-5554` 和
  `/Applications/RimeUpdater.app`，两端启动确认成功；Mac 旧应用保存在
  `dist/install-backups/20261104-235652/RimeUpdater.app`。设置与 Rime 个人数据保留。
- **手机交付**：整行「一键更新」+ 并排检查 / 预演，37 项测试与静态分析通过；Android
  release APK 构建、v2 签名校验、API 35 模拟器覆盖安装 / 冷启动 / 截图通过。安装包与 SHA256
  在 `dist/RimeUpdater-v1.0.0-ui-v3-android.apk` / `.apk.sha256`，沿用项目测试签名；
  真机已安装 ARM64 分包并启动，功能待用户验证。
- **上一轮完成**：参考 awesome-design-md 的 Linear / Raycast 重做 Flutter UI v3（雾白淡紫、
  桌面侧栏、更新卡、手机整体滚动）；设计规范与 macOS 原生标题同步更新。静态分析无问题，
  37 项测试通过；macOS release 已构建并查看实际界面；真实下载校验与只读预演通过。
- **既有工作记录**：Windows 实机（小狼毫 / 虎韵分别识别、`Tigrime.Deployer.exe`
  部署改异步、设备「⋮」删除 + `hidden_dirs`）；品牌与 UI v2「冷霜」（改名 Rime 更新器、
  新图标、`DESIGN.md`、桌面双栏 + 深色控制台 + TOOLS 工具条、手机单页）；
  iOS Scripting 更新器（预演、本地 zip、备份回滚、换方案、WebDAV 云同步，脚本 1.3.0
  改「主页 + 子页面」排版：主页状态卡 / 更新 / 目录，云同步 / 备份 / 换方案 / 设置 /
  日志拆子页面，见第 6 节第 35 条，未真机验证）
- **已验证**：`dart analyze` 无问题；`flutter test` 33 项通过（Windows 上个别临时目录
  清理偶发 `errno 32`，重跑即过）；macOS 实跑（三前端识别、预演 8 文件）；Android 模拟器
  （API 35）检查 / 预演 / 正式更新 + 快照；`flutter build windows --release` 成功并安装到
  `%LOCALAPPDATA%\Programs\RimeUpdater`；Windows 界面「一键更新」实跑两设备 0.3.1/0.3.2 →
  v0.3.23（快照 + 部署成功）；桌面 / 手机两套布局截图验证
- **未验证（优先做）**：Windows 界面回滚；Android 真机 + Trime 实际部署；iOS Scripting
  真机；真实 WebDAV 账号（坚果云 / Nextcloud，注意 301/409）
- **不要改的约定**：启动不自动请求 GitHub；更新覆盖前必须有快照 / 备份；
  `*.userdb`、`user.yaml` 等个人数据不参与方案覆盖；云同步只走 `<kind>/files/<相对路径>`
- **本机数据**：设置 / 设备 ID / 备份都在第 0 节列出的应用支持目录，不在仓库里
