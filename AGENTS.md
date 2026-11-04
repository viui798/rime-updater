# AGENTS.md — rime 更新器 工作记录与交接

> 给接手的 agent / 未来的自己：先读本文，再动手。约 2 分钟。

## 1. 项目是什么

芝士虎整（虎码 Rime 整合包）的**多设备一键更新器**，独立仓库维护：

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

- `update_desktop.py`：核心逻辑 + 命令行（纯标准库）
- `gui_app.py`：本地 Web UI 服务（`127.0.0.1:8765`），提供检查/更新/回滚/设置与任务日志
- `web/`：界面（`index.html` / `app.js` / `style.css`），无外部依赖、无 CDN
- `build_app.py`：打包 macOS `dist/RimeUpdater.app`、Windows `dist/启动更新器.bat`
- 已实测：mac 鼠须管 / 小企鹅（Fcitx5）/ 元书（Cobra）三前端，v0.3.23 增量包 8 文件、
  SHA256 通过、`Squirrel --reload` 与 `fcitx5-curl` 部署执行成功、元书提示手动
- 图形界面已用浏览器实测：设备卡片、设置弹窗、检查、预演全流程通过，控制台无报错
- 快照与回滚已在临时目录实测：覆盖/新增/删除均能正确还原，版本标记同步回退
- 远端选择已验证：`--check` 优先选中 `cheese-tiger-v0.3.23-update.zip`
- 匿名可访问：不设 `GITHUB_TOKEN` 也能拉取 Release（token 仅避开 API 限流）
- Windows（小狼毫 / 虎韵）代码路径已写，**未在 Windows 实机验证**
- Android / iOS 未接入

## 3. 文件说明

| 文件 | 说明 |
|---|---|
| `update_desktop.py` | 核心：profile 探测、资产选择、下载校验、解包应用、部署、快照/回滚 |
| `backup_userdata.py` | 用户数据备份 / 恢复：个人数据打包 zip，`--restore` 解回用户目录 |
| `gui_app.py` | 本地 HTTP 服务与界面 API，调用核心逻辑 |
| `web/` | 界面资源，随服务一起提供 |
| `build_app.py` | 生成 macOS `.app` 与 Windows 启动器 |
| `README.md` | 面向使用者的说明 |
| `LICENSE` | GPL-3.0，与方案包一致 |
| `dist/` | 打包产物，已在 `.gitignore`，不要提交 |

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
   `WeaselServer /q` + `WeaselDeployer /deploy`；元书没有 CLI 部署接口，只能提示或重启。
6. **只用标准库**：用户机器不一定有 pip 环境；代理通过 `urllib` ProxyHandler 支持。
7. **不做自动升级自身**：脚本从仓库直接运行时没有可靠的自我替换路径，先保持手动。
8. **界面用本地 Web 而不是原生 GUI**：复用全部核心逻辑、跨平台一致，
   也避免引入 Tkinter 之外的第三方界面库；`.app` 只是薄启动壳，逻辑仍在 Python 里。
9. **快照上限 32MB**：模型文件太大，全部快照会让磁盘翻倍；超大文件只记录、不复制，
   回滚时明确提示无法恢复。
10. **任务串行**：同一时刻只允许一个更新 / 回滚任务，避免两个进程同时写同一目录。

## 5. 验证清单（改脚本后必跑）

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

# 5) 界面
python3 gui_app.py --port 8766 --no-browser &
curl -s http://127.0.0.1:8766/api/state
curl -s -X POST http://127.0.0.1:8766/api/run -d '{"action":"check"}'
curl -s http://127.0.0.1:8766/api/job

# 6) 打包
python3 build_app.py && ./dist/RimeUpdater.app/Contents/MacOS/RimeUpdater
```

真实更新前建议先 `--dry-run`；`--deploy` 会不会打断输入取决于前端，元书/小企鹅可加 `--restart`。
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

## 7. 下一步（按优先级）

1. **Windows 实机验证**：在装了 小狼毫 + 虎韵 的机器上跑
   `python3 update_desktop.py --list-profiles`、`--dry-run`，再跑 `python3 build_app.py`
   用 `启动更新器.bat` 打开界面，确认
   ① 能同时识别两个用户目录；② `WeaselServer` 路径探测正确；
   ③ 部署后候选正常。若虎韵目录不在扫描深度内，调 `find_windows_profiles()` 深度或加注册表探测。
2. **界面增强**：`--check` 显示落后版本数；失败自动重试一次；下载可暂停/继续；
   把 `backup_userdata.py` 的备份 / 恢复接进界面（目前只有命令行）。
3. **Android**：Trime 用户目录 `/sdcard/rime-cheese` 可通过 ADB push；
   可加 `--adb <serial>` 走 `adb push` + 触发 Trime 重新部署（需实机确认路径与广播）。
4. **iOS**：无文件系统直写，只能走快捷指令/分享安装；暂不做。
5. **体验**：代理支持 `ALL_PROXY` 环境变量；`--source` 支持 `.tar.gz`（目前只认 zip）。
6. **测试**：当前靠手工验证。可补一个 `tests/test_apply_zip.py`：构造临时 zip 与
   `DELTA.json`，断言用户数据不被覆盖、deletions 生效、`full_required` 拒绝、快照可回滚。
7. **签名与图标**：`.app` 目前无图标、未签名；分发给他人的话需要 codesign / 公证。

## 8. 提交规范

- 中文提交信息，说明「为什么」，不要只写「更新脚本」；
- 改脚本必须跑第 5 节清单，并在提交信息里写验证结果；
- 不提交 `__pycache__`、下载缓存、任何用户目录内容。
