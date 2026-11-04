# rime 更新器

给 [芝士虎整](https://github.com/viui798/viui-tiger-sentense)（虎码 Rime 整合包）用的多设备一键更新工具。
提供图形界面与命令行两种用法，只用 Python 3 标准库，不需要安装依赖。

进度、设计决策与后续计划见 [AGENTS.md](AGENTS.md)。

## 它解决什么

方案包每次更新，都要在每台设备上手动解压、覆盖、重新部署；设备一多就容易漏文件，
还可能误覆盖用户词典和开关记忆。这个工具负责：

- 自动识别本机的 Rime 用户目录；
- 优先下载 Release 里的增量包（`*-update.zip`），没有则用完整包；
- 校验 SHA256、跳过用户数据、必要时备份自定义配置；
- 按前端执行部署 / 重启；
- 更新前完整快照，出问题可一键回滚。

## 图形界面

```bash
python3 gui_app.py          # 启动后自动打开浏览器
```

macOS 上也可以打包成可双击的软件：

```bash
python3 build_app.py        # 生成 dist/RimeUpdater.app
```

界面里可以：查看各设备当前版本、检查远端最新、一键更新或仅预演、看实时日志与进度、
改设置（仓库 / 代理 / Token / 缓存目录 / 是否部署重启 / 是否快照）、按备份回滚。
Windows 下运行 `python3 build_app.py` 会生成 `dist/启动更新器.bat`。

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
- Android / iOS 尚未接入，仍需手动同步；
- 只解决文件传输，方案编译由各前端自己的部署流程完成。

## 许可证

GPL-3.0，与上游方案包一致。
