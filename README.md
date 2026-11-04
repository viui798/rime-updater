# rime 更新器

给 [芝士虎整](https://github.com/viui798/viui-tiger-sentense)（虎码 Rime 整合包）用的多设备一键更新工具。
主客户端是 Flutter 写的原生桌面应用，另附纯标准库的 Python 命令行实现。

进度、设计决策与后续计划见 [AGENTS.md](AGENTS.md)。

## 它解决什么

方案包每次更新，都要在每台设备上手动解压、覆盖、重新部署；设备一多就容易漏文件，
还可能误覆盖用户词典和开关记忆。这个工具负责：

- 自动识别本机的 Rime 用户目录；
- 优先下载 Release 里的增量包（`*-update.zip`），没有则用完整包；
- 校验 SHA256、跳过用户数据、必要时备份自定义配置；
- 按前端执行部署 / 重启；
- 更新前完整快照，出问题可一键回滚。

## 原生桌面应用（Flutter）

`app/` 是跨平台客户端：一套 Dart 代码，同一个原生窗口界面覆盖 macOS 与 Windows，
后续接 Android / iOS 也可以复用。

```bash
cd app
flutter pub get
flutter test            # 纯 Dart 验证，不需要 Xcode
flutter run -d macos    # 需要完整 Xcode
flutter build macos     # 产物：build/macos/Build/Products/Release/RimeUpdater.app
```

Windows 版在 Windows 机器上执行 `flutter build windows`。

界面包含：设备列表与当前版本、检查更新、一键更新、仅预演、实时日志与进度、
设置（仓库 / 代理 / Token / 缓存目录 / 自动部署 / 重启 / 快照）、备份列表与一键回滚，
以及**从本地 zip 安装**：可以选择任意方案压缩包（雾凇拼音、白霜等）装到选中的设备，
个人数据不会被覆盖，安装前同样会自动快照。设备识别不全时，点设备区右上角的「+」
可以手动指定 Rime 用户目录，选择结果会保存在设置里；手动添加的设备可以点铅笔图标改名。
设备、日志、备份三块区域之间的分隔条可以拖动调整高度，双击分隔条恢复默认。
检查更新时日志会标注「（最新）」或「（可更新）」，备份区右上角可以一键「清理备份」。
启动时**不会自动联网**：只有点「检查更新」才会请求 GitHub；检查结果在 10 分钟内会被
「仅预演 / 一键更新」复用，避免重复消耗 API 额度（匿名请求只有 60 次/小时）。

**换方案向导**会按顺序完成：备份个人数据 → 清空旧方案的运行文件 → 安装新包 →
恢复个人数据并重新部署。切换前的个人数据保存在
`~/Library/Application Support/CheeseTigerUpdater/switch-backups/<时间戳>/<前端名>/`。

**GitHub 方案**入口支持填入任意方案仓库地址（如
`https://github.com/iDvel/rime-ice`），读取最近一次 Release 的 zip 资产，
选择后下载并安装到勾选的设备；带 `-update.zip` 的资产会优先选中。
雾凇拼音的 `full.zip` 已用预演验证：识别为 68 个文件，用户数据正常跳过。

**云同步（WebDAV）**：点远端行的「云同步」，填入 WebDAV 地址、用户名、密码与本机名称
（坚果云、Nextcloud 等均可），勾选设备后：

- 「上传本机」：把个人数据（自造词、调频、开关记忆、统计与 `*.userdb`）放进同步库；
- 「添加文件」：从该设备目录里单独选一个文件加入同步库（主题、自定义补丁等也行）；
- 「下载云端」：把同步库里全部文件写回本机，覆盖前自动备份，并按设置自动部署；
- 展开「同步库文件」可以看到每个文件的来源设备与上传时间，点垃圾桶可从云端删除
  （只删云端，本机文件不动；`*.userdb` 会显示为一项并整组删除，避免删坏词典数据库）。

主界面另有「同步库」入口，是一个文件夹形式的文件管理器：根目录列出各个端，
点进去按目录层级浏览同步库里的文件；右上角「+」可以从任意一端挑一个文件上传，
点文件可以在线编辑文本（yaml / txt / lua / json 等），也能直接删除云端那份。
`*.userdb` 在列表里显示为不可展开的一项，删除时整组移除。

云端目录是 `CheeseTigerSync/<前端>/files/<相对路径>`，同目录的 `manifest.json`
记录文件清单、上传设备与时间；同步库按前端共用，方案文件与模型不建议放进去。
覆盖前的备份在
`~/Library/Application Support/CheeseTigerUpdater/switch-backups/<时间戳>/<前端名>-同步前/`，
可在「备份与回滚」中查看。配置保存在设置文件的 `sync_url` / `sync_user` /
`sync_password` / `device_name` 字段。

当前状态：界面与核心逻辑已完成，静态分析无问题，33 个测试（过滤规则、增量包解包、
快照回滚、扁平/带目录 zip、版本推断、Rime 包识别、换方案备份与清理、手动目录与重命名、
无变化跳过、云同步上传/删除/下载/在线编辑、同步库文件树、WebDAV 客户端、首页与弹窗渲染）
全部通过；macOS 安装包已构建并实跑验证
（三前端识别、远端 v0.3.23、预演 8 个文件），带老虎主题应用图标。产物在
`app/build/macos/Build/Products/Release/RimeUpdater.app`，DMG 由
`cd app && ./tool/make_dmg.sh` 生成。

Windows 版代码路径已完成（窗口标题、ico 图标、注册表探测），但需要在 Windows 上构建。
仓库自带 GitHub Actions（`.github/workflows/build.yml`），推 tag 时会自动构建
macOS DMG、Windows zip 与 Android APK 并创建 Release；也可以在 Actions 页面手动触发。

本机 Xcode 装在 `/Applications/Xcode-16.2.0.app`。如果 `xcode-select` 仍指向命令行工具，
构建时加 `DEVELOPER_DIR`：

```bash
DEVELOPER_DIR=/Applications/Xcode-16.2.0.app/Contents/Developer flutter build macos
```

## Android（同文 / Trime）

`app/` 同一套代码也能构建成 Android 应用，目前按同文输入法（Trime）的默认目录设计：

- 首次启动会请求「所有文件访问权限」（MANAGE_EXTERNAL_STORAGE），用于直接读写
  `/storage/emulated/0/rime`；该权限只适合自用分发，不适合上架 Google Play；
- 自动识别 `/storage/emulated/0/rime` 与旧版
  `/storage/emulated/0/Android/data/com.osfans.trime/files/rime`；
- 更新、预演、本地 zip 安装、云同步、同步库都可直接使用；手动添加目录入口在 Android 上隐藏；
- 更新器无法调用 Trime 的部署接口，复制完成后请在 Trime 里点右上角刷新图标重新部署；
- 构建：`flutter build apk --debug`（需要 JDK 17 + Android SDK 36），产物
  `app/build/app/outputs/flutter-apk/app-debug.apk`，拷到手机安装即可。

## 备用界面（Python）

```bash
python3 gui_app.py          # 启动本地界面，自动打开浏览器
python3 build_app.py        # 生成基于 Python 的 dist/RimeUpdater.app 与 Windows 启动器
```

Python 版在浏览器里操作，功能与 Flutter 版一致，适合不想装 Flutter 环境的机器。

## 命令行

```bash
# 看识别到哪些前端、当前版本、远端最新
python3 update_desktop.py --check

# 只预演，不写盘
python3 update_desktop.py --dry-run

# 正式更新并部署
python3 update_desktop.py --yes --deploy --restart
```

方案仓库是公开的，通常不需要 token。GitHub 对匿名 API 有每小时请求上限，
频繁运行或遇到 403 时再设置：

```bash
export GITHUB_TOKEN=$(gh auth token)   # 或 GH_TOKEN
```

或者完全不走 GitHub，直接指定本地包 / 直链：

```bash
python3 update_desktop.py --source ~/Downloads/cheese-tiger-v0.3.23-update.zip --yes
```

## 参数

| 参数 | 说明 |
|---|---|
| `--list-profiles` | 列出识别到的用户目录与当前版本 |
| `--check` | 只检查版本，不下载 |
| `--source <zip/url>` | 本地包或直链，跳过 GitHub |
| `--target <目录>` | 手动指定用户目录（可重复） |
| `--version vX.Y.Z` | 指定 tag，默认 latest |
| `--deploy` / `--restart` | 执行部署 / 重启前端 |
| `--dry-run` / `--yes` | 预演 / 不询问 |
| `--proxy` | 例如 `socks5://127.0.0.1:1080` |
| `--cache-dir` / `--no-cache` | 下载缓存设置 |
| `--snapshot` | 更新前完整快照（界面默认开启） |
| `--rollback <时间戳>` | 回滚到指定备份，配合 `--deploy` 可回滚后重新部署 |

## 识别的前端

| 平台 | 前端 | 用户目录 |
|---|---|---|
| macOS | 鼠须管 | `~/Library/Rime` |
| macOS | 小企鹅（Fcitx5） | `~/.local/share/fcitx5/rime` |
| macOS | 元书（Cobra） | `~/Library/Application Support/com.ihsiao.inputmethod.Cobra/RimeUserData` |
| Windows | 小狼毫（Weasel） | `%APPDATA%\Rime` |
| Windows | 虎韵及其他 | 扫描 `%APPDATA%` / `%LOCALAPPDATA%` 深度 ≤4，含 `tiger*.schema.yaml` 的目录 |

部署方式：

- 鼠须管：`Squirrel --reload`，找不到时回退 `rime_deployer --build`；
- 小企鹅：`fcitx5-curl /config/addon/rime/deploy`，找不到时按 `--restart` 重启；
- 元书：无命令行部署接口，按 `--restart` 重启，或手动重新部署；
- 小狼毫：`WeaselServer /q` → `WeaselDeployer /deploy` → 重新拉起 `WeaselServer`。

## 不会覆盖的数据

- `*.userdb/`（用户词典与学习记录）、`*.options.yaml`（开关记忆）；
- `user.yaml`、`installation.yaml`、`reverse_freq.txt`、`custom_phrase.txt`；
- `build/`、`sync/`、`lua/kc_count.txt`、`lua/kc_total.txt`、`lua/input_stats_*.lua`；
- 已有的 `*.custom.yaml` 覆盖前备份到 `.cheese-tiger-backup/<时间戳>/`；
- 开启快照时，所有被覆盖 / 被删除的文件都会备份到 `.cheese-tiger-backup/<时间戳>/`，
  并写入 `manifest.json`，可用界面或 `--rollback` 还原；超过 32MB 的文件只记录不备份；
- 完整包里 405MB 的模型若目标目录已有同尺寸文件则跳过复制。

成功后写入 `.cheese-tiger-version`，`--check` 显示的当前版本来自它。

## 用户数据备份

方案升级不该动个人数据，但换设备、重装或换前端前，先备份一份更稳妥：

```bash
python3 backup_userdata.py --list       # 先看会备份哪些文件
python3 backup_userdata.py --yes        # 每个前端一个 zip，默认 ~/Desktop/芝士虎整备份/
python3 backup_userdata.py --restore <备份.zip> --target ~/Library/Rime --yes
```

- 备份内容：`custom_phrase.txt`、`reverse_freq.txt`、`*.options.yaml`、`自学习-*.txt`、
  `lua/input_stats_*.lua`、`lua/kc_*.txt`、`lua/quote.txt`、`squirrel.custom.yaml`、`*.userdb`；
- 默认跳过可重建的 `lua/replacer.userdb`（需要时加 `--with-cache`），加 `--no-userdb` 可跳过用户词典；
- zip 根目录为 `userdata/`，内含 `BACKUP.json` 清单（来源、时间、版本、文件列表）；
- 建议备份前退出输入法，避免 LevelDB 正在写入；恢复后重新部署输入法。

## 增量包从哪来

增量包由方案仓库的 `tools/make_release_delta.py` 在发版时生成，随 Release 上传，
`DELTA.json` 里带文件清单与删除列表；模型变更会标 `full_required`，脚本会自动改用完整包。
本仓库不生成包，只负责安装。

## 当前边界

- Windows（小狼毫 / 虎韵）代码路径已实现，尚未在 Windows 实机验证，首次使用建议先 `--dry-run`；
- Android（同文 / Trime）客户端已在模拟器（API 35）跑通检查、预演与正式更新，待真机验证；iOS 尚未接入；
- 只解决文件传输，方案编译由各前端自己的部署流程完成。

## 许可证

GPL-3.0，与上游方案包一致。
