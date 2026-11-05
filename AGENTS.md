# AGENTS.md — rime 更新器 工作记录与交接

> 给接手的 agent / 未来的自己：先读本文，再动手。约 3 分钟。
>
> **维护规则**：本文只保留「现在仍然成立」的信息与仍会踩的坑。历史细节看 git log，
> 不要往第 6 节堆流水账——它曾经涨到 64KB，超出工作区指令预算被截断。

## 0. 接手清单（新设备 / 新 agent，5 分钟）

1. 拉代码：`git clone https://github.com/viui798/rime-updater && cd rime-updater`
   （原开发机本地目录 `/Users/viui/Desktop/rime更新器`，方案仓库在 `/Users/viui/Desktop/芝士虎整`）
2. 装 Flutter stable（原机器 3.47.9 / Dart 3.13.7），然后 `cd app && flutter pub get`
3. 跑验证：`dart analyze`、`flutter test`，当前应为 **74 项全部通过**
4. 构建：
   - macOS：`DEVELOPER_DIR=/Applications/Xcode-16.2.0.app/Contents/Developer flutter build macos --release`
   - Windows：在 Windows 机器上 `flutter build windows --release`（需 VS「使用 C++ 的桌面开发」）
   - Android：见第 5 节（JDK 17 + SDK）
5. 启动后先勾选设备 → 点「检查更新」。**启动时故意不联网**，不要改回自动检查
6. 改完代码更新第 6 节（只写仍成立的经验）与第 9 节（交接快照，覆盖写，不要追加）

运行数据都不在仓库里：

| 内容 | macOS | Windows |
|---|---|---|
| 设置 / 设备 ID / 同步状态 | `~/Library/Application Support/CheeseTigerUpdater/` | `%LOCALAPPDATA%\cheese-tiger\` |
| 换方案 / 同步前备份 | 同上 `switch-backups/` | 同上 `switch-backups/` |
| 下载缓存 | `~/Library/Caches/cheese-tiger` | `%LOCALAPPDATA%\cheese-tiger\cache` |
| Rime 用户目录 | `~/Library/Rime`、`~/.local/share/fcitx5/rime`、Cobra | `%APPDATA%\Rime`、扫描 `%APPDATA%` / `%LOCALAPPDATA%` |

Android 的设置与缓存都在应用私有目录（`files/cheese-tiger/`），换机不保留。

## 1. 项目是什么

**通用 Rime 方案更新器**：默认对接芝士虎整仓库，也支持任意 GitHub 方案或本地 zip。
品牌统一为「Rime 更新器 / RIME UPDATER」。四个发布目标：

| 目标 | 形态 |
|---|---|
| macOS | DMG（未签名 / 未公证） |
| Windows | Inno Setup 安装包 + 免安装 zip（x64） |
| Android | 分架构 APK（arm64 / armv7 / x86_64） |
| iOS | Scripting App 脚本（无需开发者账号） |

职能边界：本仓库只做客户端（识别目录、下载校验、覆盖、部署、回滚、同步、界面）；
方案包与增量包由方案仓库 `viui-tiger-sentense` 的发版流程生成。

## 2. 当前状态（2026-11-05）

- `app/` 是主客户端，一套 Flutter 代码覆盖 macOS / Windows / Android；`ios/scripting/` 是独立脚本。
- 版本 `0.10.0+36`（Android versionCode 2036 = 2000 + build number）。
- 界面为 4 个页面：**更新器 / 同步 / 更多 / 设置**。窄屏底部悬浮导航（选中胶囊横向滑动），
  宽屏左侧栏，两者都切页；切页是整屏推屏且旧页立即退场（用户明确不要残影）。
  云同步与同步库合并进「同步」页两个分段；备份与回滚在「更多」。
- 三个原弹窗（设置 / 云同步 / 同步库）支持 `embedded` 模式，弹窗与页面共用一份逻辑。
- 缓存：更新成功后只保留当前版本；设置页显示占用并可清理。Android 缓存在 `files/`（非 `cache/`）。
- Android 额外能力：Shizuku 访问 `Android/data` 受限目录；**SAF 访问元书等私有目录**（路线 A，
  见 4.13）；公共目录扫描。
- 已知未验证项见第 7 节。

## 3. 文件说明

| 文件 | 说明 |
|---|---|
| `app/lib/main.dart` | `HomePage`：4 页导航、设备表、更新/回滚/同步编排、日志。**改动最集中的文件** |
| `app/lib/core/rime_profile.dart` | 前端探测、版本读取、`shouldCopy` 过滤、备份列表、`applyCustomNames`、`clearRimeDir` |
| `app/lib/core/github_client.dart` | Release 拉取、下载、SHA256、缓存目录解析 |
| `app/lib/core/package_preparer.dart` | 三级更新阶梯（增量 → 无模型版 → 完整包）、`AlreadyLatest` |
| `app/lib/core/zip_installer.dart` | 增量包解包、快照、回滚（`archive`） |
| `app/lib/core/saf_client.dart` | SAF：选目录、持久授权、递归遍历、读写删、流式写入 |
| `app/lib/core/saf_installer.dart` | SAF 安装：过滤 + 快照 + 版本标记 + 基座校验 |
| `app/lib/core/cache_manager.dart` | 缓存统计、只保留最新、手动清理（只动本工具产出的文件） |
| `app/lib/core/scheme_switcher.dart` | 换方案：收集个人数据 → 备份 → 清理 → 恢复 |
| `app/lib/core/deployer.dart` | 按前端部署（Squirrel / fcitx5 / Weasel / 虎韵 / Cobra） |
| `app/lib/core/webdav_client.dart` / `sync_service.dart` | WebDAV 客户端与同步库逻辑 |
| `app/lib/core/settings_store.dart` | 设置读写、缓存路径解析、旧缓存迁移 |
| `app/lib/core/android_profiles.dart` | Shizuku 暂存区与 diff 提交（`withProfileDirectory`） |
| `app/lib/ui/home_nav.dart` | 底部导航（滑动胶囊） |
| `app/lib/ui/sync_dialog.dart` / `sync_library_dialog.dart` / `settings_dialog.dart` | 可内嵌的页面组件 |
| `app/android/.../ShizukuBridge.kt` / `RimeFileService.kt` | Shizuku 绑定与受限目录文件服务 |
| `app/test/` | 9 个测试文件，74 项；改核心逻辑必须补测试 |
| `ios/scripting/cheese-tiger-updater/` | iOS 脚本（1.4.0，四 Tab） |
| `.github/workflows/build.yml` | 推 `v*` tag 或手动触发：三平台构建，tag 时建 Release |
| `update_desktop.py` / `gui_app.py` / `web/` / `build_app.py` | Python 参照实现与备用 Web 界面 |
| `DESIGN.md` | 设计基准（雾白 + 淡紫），改界面前必读 |

## 4. 设计决策（踩过坑才定下来的，别轻易改）

1. **增量包优先，但基座不符一律回退完整包**：宁可多下 341MB，也不能出现
   「版本号前进了、文件底子没跟上」的坏安装（见第 6 节事故记录）。
   客户端、SAF 路径、iOS 脚本都必须做这个校验。
2. **白名单跳过用户数据**：`*.userdb`、`user.yaml`、`*.options.yaml`、统计 lua、`build/`、`sync/`、
   `*.md` 等一律不覆盖。宁可少更新一个文件。
3. **版本标记独立于 Rime 配置**：桌面用 `.cheese-tiger-version`；**SAF 目录必须用不带点的
   `cheese-tiger-version.txt`**（元书 provider 会把点开头的名字改成 `N.原名`）。
4. **快照上限 32MB**：超大文件只登记不备份，回滚时明确提示无法恢复。
5. **任务串行**：同一时刻只允许一个更新 / 回滚任务。
6. **启动不联网**：只有用户点「检查更新」才请求 GitHub，结果缓存 10 分钟复用。
7. **设置文件跨客户端共用**：Flutter 与 Python 读写同一路径，切换客户端不用重配。
8. **云同步用「共用文件库」**：`CheeseTigerSync/<kind>/files/<相对路径>` + `manifest.json`，
   可单文件增删，不依赖 PROPFIND。
9. **只用标准库（Python 侧）**：用户机器不一定有 pip。
10. **快照 / 部署 / 过滤的行为在 Python 与 Dart 两侧保持一致**：改一侧要对照另一侧。
11. **缓存只留当前版本**：每次发版都会多一份完整包（341MB），不清理会无限堆积。
    清理只删本工具产出的文件，绝不碰用户其他内容（缓存目录允许自定义）。
12. **界面：弹窗与页面共用一份逻辑**（`embedded` 开关），不要复制两套 UI。
13. **Android SAF 采用路线 A**：SAF 目录只支持「添加 / 检查 / 预演 / 更新」；
    换方案、云同步、回滚、清空目录不支持（菜单里相应隐藏）。
    **SAF 无法触发输入法部署**，写完必须由用户在元书内重新加载。
14. **已是最新的设备直接跳过**：不再重复遍历文件与重复部署（重启输入法很扰民）。
15. **单设备失败不中断整批**：记录后继续；状态栏汇总部分失败。

## 5. 验证清单（改代码后必跑）

```bash
cd app
dart analyze                      # 必须无问题
flutter test                      # 当前 74 项，全绿

# macOS
DEVELOPER_DIR=/Applications/Xcode-16.2.0.app/Contents/Developer flutter build macos --release

# Android（本机环境）
export JAVA_HOME="$HOME/android/jdk17/Contents/Home"
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
export ANDROID_SDK_ROOT=/opt/homebrew/share/android-commandlinetools
export GRADLE_OPTS=-Dorg.gradle.daemon=false
flutter build apk --release --split-per-abi    # ARM64 versionCode = 2000 + build

# iOS 脚本
cd ../ios/scripting/cheese-tiger-updater
npx --no-install esbuild index.tsx --bundle --loader:.tsx=tsx --external:scripting --outfile=/tmp/ct.js
```

注意事项：

- 装到手机：`adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`，
  versionCode 必须递增（pubspec 的 `+N` 每次都要加）。
- macOS 替换 `/Applications/RimeUpdater.app` 前先 `pkill -f RimeUpdater`，否则旧进程仍在跑。
- `flutter test` 里涉及真实文件系统的用例会读本机 `~/Library/Rime` 等目录；没有设备的机器上
  相关断言会自动跳过或使用临时目录。
- Python 侧改动：`python3 -m py_compile update_desktop.py gui_app.py`，再用
  `python3 update_desktop.py --dry-run --yes` 预演，别直接动真实用户目录。

## 6. 仍然成立的经验（踩过的坑）

**增量包与基座**
- 增量包只含「相邻 tag 之间变化的文件」，补不上老底子缺的新增文件。曾导致小企鹅 / 元书
  更新后打不出字（缺 `yin_full.lua`、`tiger_full.dict.yaml`、`tiger_sentence_dispatch.lua` 等）。
  根治方向：方案仓库改为「相对最老支持基线出增量」或 DELTA.json 带必需文件清单。
- 因此客户端三处都必须校验基座：`zip_installer.applyZip`、`saf_installer.applyZipToSaf`、
  iOS `installZip`。基座不符或 `full_required` → 要求完整包。
- 词典编译要求同名 `.schema.yaml` 存在，否则日志报 `missing input schema` 并静默跳过。

**Android / SAF**
- `pickDirectory` 必须显式传 `persistablePermission: true`，否则重启后 Permission Denial。
- 元书（Hamster）拒绝点开头的文件与目录：`.cheese-tiger-backup` 创建失败，
  `.cheese-tiger-version` 被改名成 `1./2./3.cheese-tiger-version`。改用不带点名字并自动清理残留。
- SAF 预演必须传 `dryRun`——曾经预演会真实写盘，把用户目录改了。
- 大文件不能整份读进内存比较（387MB 模型会 OOM）：按大小判定 + 流式分块写
  （`ArchiveFile.getContent()` + `readInto` + `startWriteStream/writeChunk`）。
- Shizuku 的 `svc.read()` 对无权限或已删文件返回空，必须判空跳过，否则整批中断。
- `files()` 扫描要跳过 `build/` 与 `sync/`。
- 小米 / MIUI 会清 `cache/`，缓存必须放 `files/`。
- Android 覆盖安装要求 versionCode 单调递增。

**设置与状态**
- `Settings` 是手工逐字段重建的（`settings_dialog._collect()`），**加字段必须同步那里**，
  否则保存一次就把新字段清空（曾把 SAF 目录清掉）。
- `applyCustomNames` 在没有自定义名称时返回**同一个 list**，调用方必须重新赋值，
  不能 `profiles..clear()..addAll(renamed)`（会把自己清空，设备列表变 0）。
- 自动识别、Shizuku、SAF 设备的改名都靠 `customNames[profile.path]`，统一在
  `_refreshProfiles` 末尾覆盖，不要在各自的构造函数里处理。

**部署**
- fcitx5 的 POST 部署（`/config/addon/rime/deploy -X POST`）有效，但成败要看 build mtime。
- 元书有官方 CLI：`Cobra deploy` / `sync` / `print`（`print` 可探测权威用户目录）。
- 小狼毫部署要区分服务重启与部署两步；`WeaselServer` 的 workingDirectory 必须是其安装目录，
  否则卸载后残留空文件夹。

**界面**
- 用户对动效有明确偏好：底栏是「滑动胶囊」而不是按压缩放；切页是**整屏推屏**且
  **旧页必须立即退场**（不允许残影）。改动前先看 `home_nav.dart` 与 `_buildAnimatedPage`。
- 窄屏（320px）与 1.2 倍字号要能跑，标签用 `Flexible` + ellipsis，不要硬塞。

## 7. 下一步（按优先级）

1. **SAF 真实写入未验证**：预演是只读的，`applyZipToSaf` 的落盘只在单测里跑过。
   元书当前 `v0.3.2`，远端 `v0.3.26`，差 24 个版本会走完整包（341MB）——首次真实更新要盯住。
2. **元书版本标记未写入**：文件内容其实已是 v0.3.26，但没有 `cheese-tiger-version.txt`，
   所以一直显示「可更新」。点一次「一键更新」即会写入并变为「已最新」。
3. **iOS 1.4.0 未真机验证**：四 Tab 布局、增量基座校验都只过了 esbuild。
4. **Windows 构建**：需在 Windows 机器上跑；`jni`（来自 `saf_stream`）会作为 FFI 插件参与，
   其 CMake 对 JDK 是可选的，理论上不需要装 JDK。
5. **云同步真实账号验证**：坚果云 / Nextcloud，注意 301/409 未处理。
6. **Windows 回滚实跑**、**界面完整更新 + 回滚实跑**。
7. 体验：Dart 桌面端不支持 socks5；分发需要 macOS 签名与公证。

## 8. 提交规范

- 中文提交信息，说明「为什么」，不要只写「更新脚本」；
- 改代码必须跑第 5 节清单，并在提交信息里写验证结果；
- 不提交 `__pycache__`、下载缓存、`dist/`、任何用户目录内容。

## 9. 交接快照（每次会话结束**覆盖**这一节）

> 2026-11-05 · `main` · Android SAF（元书）接入、缓存管理、四页界面改版、iOS 四 Tab

**已提交**（本地，尚未 push 前请先 `git log` 确认）：原生修复 `57f00f9`、主体功能 `a9e7753`、
iOS 基座校验 `95f537d`、忽略与工具 `180a6c2`、文档 `e6bc4cb`、iOS 四 Tab `d5ded04`。
`dart analyze` 干净，`flutter test` 74 项全过。

**已安装验证**：Android 真机 versionCode 2036（四页、底栏滑动、SAF 添加与预演、改名、Shizuku 状态）；
macOS `/Applications/RimeUpdater.app` 已重装并实跑；产物在 `dist/RimeUpdater-v0.10.0-build36-*`
（被 git 忽略）。iOS 脚本 1.4.0 只过了 esbuild。

**元书现状**：SAF 目录已加、授权可持久、预演通过（172 个文件全部「未变化」），
但版本标记未写入，仍显示「可更新 v0.3.2」。**真实写入未验证**。

**不要踩的坑**：见第 6 节；新增字段记得改 `settings_dialog._collect()`；SAF 不能用点开头的名字。

**`.zcode/` 仍未跟踪，按要求保留，不要删除。**
