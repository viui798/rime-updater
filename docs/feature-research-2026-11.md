# 功能与优化调研（2026-11-05）

> 针对更新器（本仓库）与芝士虎整（方案仓库）的系统性功能调研。方法：四路并行检索
> （Rime 生态、通用更新框架、配置同步与 WebDAV、前端部署与 API 优化）+ GitHub API
> 直接扫描。本文档随调研推进持续补充，最终结论在「优先级路线」一节。

## 0. 一页结论（先看这里）

| 优先级 | 事项 | 来源 | 直指的问题 |
|---|---|---|---|
| P0 | 增量包改「固定基线」+ DELTA.json 带文件级 hash 清单 | FuyaoRime / ostree 思想 | 0.3.24 事故（老底子缺文件/伴随文件漂移，版本标记拦不住） |
| P0 | 删除版本标记 → 下次全量重建的「重置基线」逃生门 | FuyaoRime | 更新坏了想重来没有简单出口 |
| P0 | 云同步改用 Rime 原生 userdb 快照合并（sync/<id>/*.txt） | rime/squirrel#186、Hare | 现在整文件覆盖会丢掉被覆盖设备的输入习惯 |
| P1 | 下载：断点续传 + 指数退避重试 + 多镜像（CNB/NJU/ghproxy） | snout / wanxiang-updater / NJU mirror | 357MB 完整包在国内基本下不动；断网从头再来 |
| P1 | ed25519 签名 manifest 与包（`cryptography` 包验签，公钥内置客户端） | Sparkle/Tauri（§4.A4） | 现在只有 zip 级 SHA256，防损坏不防篡改 |
| P1 | GitHub API ETag 条件请求（304 不占限流额度） | GitHub docs（§4.A7） | 匿名 60 次/小时易耗尽 |
| P1 | 「修复」动作：按清单核对 + 补齐缺失文件 + 部署 | Omaha/ostree（§4.A10） | 老底子存量用户一键救回 |
| P1 | 客户端 SOCKS5 代理（pub.dev 有现成包可查证） | wanxiang-updater | AGENTS 已记录 Dart 桌面仅支持 HTTP 代理 |
| P1 | 资产拆分：词库/方案/模型独立 zip + 预编译包（含 build/） | rime-ice nightly | 词库小改动也要下整包；移动端部署慢 |
| P1 | 界面「重置/落后版本数/失败重试」三件套 | 各竞品 | AGENTS 下一步清单 |
| P2 | 方案适配器注册表（内置雾凇/白霜/万象/薄荷预设卡片） | snout / 仓输入法方案下载 | 「GitHub 方案」要用户自己填仓库 |
| P2 | 前端导入包兜底（生成标准 zip 走系统分享） | rimeinn / fcitx5-android / 元书 .hschema | Shizuku 进不去的私有目录 |
| P2 | 更新通道（稳定/追新滚动版）、定时检查（默认关） | 万象双轨发布 / FuyaoRime | 追新党与稳定党需求 |
| P3 | 模型独立仓发 Release、发布附评测报告、release-please | rime-wanxiang-data / RIME-LMDG | 发版流程改造 |
| P3 | 包管理器分发（Homebrew cask / scoop / choco）补足自更新 | snout CI | 「不做自动升级自身」的替代路径 |

---

## 1. 竞品与同类项目盘点

### 1.1 ca-x/snout（Rust，Rime 社区最成熟的更新器）

多方案更新器：万象（10 变体）+ 雾凇 + 白霜 + 薄荷；TUI 界面；Rime 生态事实上的标杆。

对本项目直接有用的能力（均已验证存在）：

- **模型自动 patch**：下载 `wanxiang-lts-zh-hans.gram` 后按方案自动写 `*.custom.yaml`
  并补 `translator/contextual_suggestions` 等参数——装完即生效，用户不用懂配置
- **非交互 CLI + JSON 输出**：`--json` 输出 `{schema_version, ok, results}`，
  供脚本/计划任务消费；zsh/fish 自动补全
- **SOCKS5 / HTTP 代理**、**CNB 镜像加速**、**断点续传（HTTP Range）**、SHA256 校验
- **皮肤 Patch**：内置 6 主题一键切换（写 custom.yaml + fcitx5 themes）
- **分发**：AUR / Chocolatey / Homebrew tap，CI 自动推送
- 仓库：https://github.com/ca-x/snout
- 实机反馈（appinn/V2EX）：Windows TUI 启动卡、方向键延迟——我们的 Flutter GUI 是差异化优势

### 1.2 ca-x/rime-wanxiang-updater（Go，★84，snout 前身）

- 词库 / 方案 / 模型三类对象**分开检查与更新**
- 配置含 `exclude_files` 排除规则与更新前/后 **Hook**
- 包管理器分发同上；CNB 镜像；断点续传
- 仓库：https://github.com/ca-x/rime-wanxiang-updater

### 1.3 UTAKO-TAKI/rime-bidirectional-sync（Windows 小狼毫）

- 按 **SHA-256 双向增量同步**；每设备独立 **head、版本向量、删除标记、冲突备份**
- OneDrive / 本地同步文件夹 / WebDAV 三种后端
- 默认每日 09:00/13:00/21:00 **定时静默运行**
- **第三方词库订阅**：直接消费 outloudvi/mw2fcitx 的 Release（萌娘百科词库），7 天一查
- 安装/升级/卸载前自动备份；小狼毫右键菜单集成
- 「安装器只修改 SHA-256 与已核验一致的二进制，未知版本拒绝覆盖」——与我们 0.3.24 后
  的基座校验同一哲学，但做到了文件级
- 仓库：https://github.com/UTAKO-TAKI/rime-bidirectional-sync

### 1.4 YatsukiRenka/Hare 紫毫（小狼毫分支）

- **端到端加密云同步**；四种后端：本地目录 / S3 兼容 / WebDAV / Cloudflare Worker 代理
- 核心设计：**不搬 userdb 原始文件**，利用 Rime 原生快照机制
  「拉远端快照 → Rime 自己合并 → 传回本机」；词频合并取较大值，**可交换且幂等，无冲突**
- 实测记录：坚果云行为已实测并「安全拒绝」（限流 quirk），改用 Worker 代理
- 仓库：https://github.com/YatsukiRenka/Hare

**官方机制核实**（rime/home wiki UserGuide「同步用戶資料」）：`installation.yaml` 加
`sync_dir: <路径>` 后，词典快照备份到 `sync/<installation_uuid>/`；多台机器把各自的
UUID 快照放进同一目录，各端执行一次同步即自动合并（词频取较大值，幂等）。
`sync_dir` 可指向 Dropbox / iCloud Drive / U 盘等任意同步位置。

对本项目的具体形态：

1. 云端同步库新增 `sync/<kind>/<uuid>/*.userdb.txt` 目录，本机快照由 WebDAV 双向搬运
   （复用现有客户端，文件少、纯文本、天然增量小）；
2. 拉取他端快照到本地 `sync_dir` → 触发前端用户词典同步（WeaselDeployer `/sync`、
   Squirrel 菜单、Trime 按钮、仓输入法官方支持 iCloud sync）；
3. macOS/iOS 可把 `sync_dir` 直接设为 iCloud Drive 里的固定目录，**零服务器多端合并**；
4. 现有「整文件覆盖」模式保留给 `*.custom.yaml` / 主题等非词库文件，两者分工：
   **词库走快照合并（无冲突），配置走覆盖（有快照兜底）**。

### 1.5 skyrocketingHong/FuyaoRime（每日聚合发版）

- 每日 Action：聚合雾凇 + 万象模型 + 拆字/维基/萌娘词库，全量 + 增量一起发
- 增量命名 `fuyaorime-YYYYMMDD-diff-from-YYYYMMDD.zip`，**from 版本显式写在包名与
  INCREMENTAL-README 里**，附删除清单
- **删版本标记文件 = 下次全量重建**（用户逃生门）
- 各平台 crontab/schtasks 定时脚本 + iOS 快捷指令
- 仓库：https://github.com/skyrocketingHong/FuyaoRime

### 1.6 其他参考

| 项目 | 一句话收获 | 链接 |
|---|---|---|
| rimeinn/rime-wanxiang-update-tools | 六平台脚本 + iOS 快捷指令 + 「同文/小企鹅导入包构建脚本」 | https://github.com/rimeinn/rime-wanxiang-update-tools |
| Mark24Code/rime-auto-deploy（★1.9k） | 部署前旧配置改名 `.old` 保留；`custom/` 模板追加；CLI 分步执行 | https://github.com/Mark24Code/rime-auto-deploy |
| amzxyz/rime_wanxiang | 滚动版 + 正式版双轨 Release；release-please 自动版本；Base/Pro/Lite/Pure 变体 | https://github.com/amzxyz/rime_wanxiang |
| amzxyz/rime-wanxiang-data + RIME-LMDG | 模型独立仓发 Release + 评测报告随发；语料/训练工具链分离 | https://github.com/amzxyz/rime-wanxiang-data |
| lotem/rime-octagram-data | 官方八股文按「字/词模型 × 繁/简」分资产 | https://github.com/lotem/rime-octagram-data |
| iDvel/rime-ice | nightly 一次产出 full.zip / cn_dicts.zip / en_dicts.zip / opencc.zip / full_compiled.zip（含 build/ 预编译） | https://github.com/iDvel/rime-ice |
| rime/plum（东风破） | recipe 机制：`owner/repo:recipe` 即包，仓库内配方可选文件子集，无需发 Release | https://github.com/rime/plum |
| NJU 镜像 | 自动同步 GitHub Release 资产的镜像站先例 | https://mirror.nju.edu.cn/github-release/iDvel/rime-ice/ |
| zishuzy/rime_userdb_merger | userdb.txt 离线合并工具（换方案保词的技术底座） | https://github.com/zishuzy/rime_userdb_merger |
| 仓输入法 / 元书官方 | CloudKit 方案下载；元书 1.2.0 起 zip 即 .hschema 自动导入；仓支持 Wi-Fi 上传 | https://ihsiao.com/apps/hamster/docs/guides/input_schema |
| Dart 生态 | **binary_patch**（bsdiff + zstd，纯 Dart）可用于大词典/模型 bin 的真二进制增量 | https://pub.dev/packages/binary_patch |

---

## 2. Rime 生态调研全量清单（42 条，按可操作性分档）

### 2.1 直接可抄（改动小、收益明确）

1. **增量包「相对固定基线」**：`make_release_delta.py` 对「最老仍受支持基线」各生成一条
   增量，DELTA.json 显式 `base_version`（FuyaoRime 已验证）→ 直指 AGENTS 第 40 条事故。难度：低
2. **「重置基线」逃生门**：界面按钮删 `.cheese-tiger-version`，下次自动全量重建。难度：低
3. **Release 资产按粒度拆分**：`dicts/`、`opencc/`、模型各自独立 zip，客户端「仅词库轻量更新」
   选小资产（雾凇 nightly 模式）。难度：中
4. **预编译包**：发版机跑一次部署，把 `build/` 产物打成 `*-compiled.zip`，Android/iOS 默认用
   （本地不编译，顺带消灭「本地编译失败」类故障）。难度：中
5. **双轨发布**：`latest.zip` 滚动资产 + 正式 tag；客户端「更新通道：稳定/追新」。难度：低
6. **多镜像下载源**：CNB / NJU / ghproxy 前缀替换 + 失败自动换源。难度：低
7. **断点续传 + 指数退避**：`Range` 头 + 临时分片；429/5xx 退避（1s 起、上限 10s、≤3 次）。难度：低-中
8. **可配置排除规则 + 更新前后 Hook**：设置弹窗 glob 排除列表；hook 先支持「更新后自动部署」。难度：低-中
9. **CLI JSON 输出**：`update_desktop.py` 与 Dart CLI 加 `--json`，对齐 snout 字段。难度：低
10. **「导出为前端导入包」**：设备行菜单生成 fcitx5-android「导入用户数据」格式的 zip 并分享
    （Shizuku 边界的官方兜底路径）。难度：低
11. **利用元书/仓的 zip 自动导入**：iOS 脚本下载后落 zip 到「文件」App 对应目录再 deep-link，
    替代逐文件写沙盒。难度：低
12. **模型自动 patch**：下载模型顺手写启用 patch（自有方案直接写，第三方只提示）。难度：中
13. **包装 Rime 原生用户词典同步**：快照落到目标端 `sync/<云端id>/` 后触发各前端 sync
    （WeaselDeployer `/sync`、Squirrel 菜单、Trime 按钮），替代整文件覆盖。难度：中-高
14. **各前端「同步用户词典」按钮**：deployer.dart 加 sync 动作。难度：低
15. **内置方案预设卡片**：「GitHub 方案」弹窗内置 雾凇/白霜/万象/薄荷 一键填入。难度：低
16. **更新前自动备份旧配置 + custom 模板保留**：换方案向导补 `*.custom.yaml` patch 类白名单。难度：低
17. **定时自动检查（默认关）**：桌面端 schtasks/launchd，iOS 快捷指令自动化。难度：中
18. **用户词迁移（换方案保词）**：解 userdb → txt → 按新方案码表转换 → 重建。难度：高
19. **方案适配器注册表**：仓库名 → 资产选择规则/版本标记路径，内置 3-5 热门方案。难度：中
20. **多版本变体选择**：按资产名区分变体（类似万象 Base/Pro/Lite）。难度：中

### 2.2 机制上更优（改发版流程或架构）

21. **plum recipe 作为第二安装路径**：`owner/repo:recipe` 拉指定文件列表落盘，兼容不发
    Release 的老方案仓库。难度：中
22. **模型/大文件独立仓**：芝士虎整把几百 MB 模型拆到独立 Release，方案包 DELTA.json 只记
    「模型版本 + URL」，客户端按需下载。难度：中-高
23. **每日聚合 Action**（如需引入外部词库）。难度：中
24. **release-please 自动版本管理**（方案仓库）。难度：低
25. **发布附变更摘要/评测报告**。难度：低
26. **动态词库清单 `extra-dicts.json`**：可选词库与方案解耦，客户端「可选组件」页。难度：中
27. **前端导入格式即分发格式**：统一「标准导入包 + 系统分享」作为受限目录兜底。难度：低
28. **patch-first 约定**：界面提示「定制请走 custom.yaml」，更新日志警告「将覆盖你直改过的
    文件」（可 diff 检测）。难度：低
29. **包管理器分发补足自更新**：Homebrew cask / scoop manifest / choco。难度：中
30. **App 内方案目录（长期）**：仓 CloudKit / fcitx5-android 插件模式的对等物。难度：高

### 2.3 参考向

31. snout 产品形态：TUI 不必抄，配置向导 / 镜像开关 / 主题切换值得抄
32. rime-auto-deploy 的分步执行 `--step`
33. oh-my-rime 三条导入路径并存 + CNB 镜像跟随最新模型
34. SyncClipboard：自托管服务端 + iOS Scripting 客户端的成熟先例
35. iCloud Drive 作 sync_dir：macOS/iOS 零服务器方案（可作 WebDAV 之外的同步后端）
36. 独立 userdb 合并工具与 userdb.txt 可读格式
37. GUI 配置工具生态（WeaselTune / RimeControl / sct / WubiMaster）：皮肤管理是另一块赛道
38. 词库编辑与格式转换（rimedm / imewlconverter / huma-rime-adder）：与用户词迁移互补
39. iOS 侧：rimeinn 双快捷指令（免装 Scripting App 的低门槛路线，与本项目脚本互补）
40. Gitee/SourceForge 镜像：手动覆盖三目录的「极简手动更新」可写进文档
41. 编辑器侧工具（Rimebow 等）：重度用户直改文件是常态 → 「检测直改并警告」有价值
42. librime-cloud：引擎级联网是 lua/插件的事，更新器保持纯粹

---

## 3. 设计草案：DELTA.json 基座文件清单（根治 0.3.24 类事故）

> **实证补充（2026-11-05 深夜，本机部署日志）**：修复老底子目录时发现，即使补齐了
> `tiger_full.dict.yaml`，librime 仍不编译词典，日志给出
> `missing input schema; skipped unsatisfied dependency: tiger_full` ——
> **词典编译还要求同名 `.schema.yaml` 存在**。这证明「依赖闭包」必须含
> schema 文件（dictionary 引用 → 同名 schema），正好验证清单方案里
> 「from tag 全量文件 hash」做法的必要性：人脑枚举依赖必漏，机器枚举不会。

现有基座校验（fe91d3a）只比对版本标记，今天实测证实它拦不住「标记对、内容漂移」：
老底子目录标记 0.3.23，但 `lua/tiger_kf.lua`、`lua/input_statistics.lua`（差 3102 行）、
`symbols.yaml` 都是旧世代内容，v0.3.24 schema 引用它们时同样会坏。业界对应物：
ostree / Nix 的内容寻址清单、rime-bidirectional-sync 的「SHA-256 与已核验一致才覆盖」。

提案（两端配合，向后兼容）：

```jsonc
// DELTA.json 新增字段（发版侧 make_release_delta.py 生成）
{
  "from": "v0.3.23",
  "to": "v0.3.24",
  "base_check": {
    "files": {
      "lua/tiger_kf.lua": "sha256-…",
      "lua/input_statistics.lua": "sha256-…",
      "symbols.yaml": "sha256-…"
      // 建议直接放 from tag 全量方案文件的 sha256（json 约几 KB，代价可忽略）
    }
  }
}
```

客户端规则（applyZip 动任何文件之前）：

- 清单里每个文件：本地缺失 → 基座不符；本地存在但 hash 不同 → 基座不符
- 例外：该文件同时出现在本增量包的 `files` 列表里（会被本次更新覆盖）则跳过检查
- 任一不符 → 走既有 `_fallbackFull` 完整包兜底，日志说明哪个文件触发了回退
- 无 `base_check` 字段的旧增量包保持现状（向后兼容）

发版侧生成方式：`git ls-tree from_tag` 逐文件 sha256，一行循环的事；
更进一步可对「to 状态的 schema/lua 引用闭包」做同样校验，双保险。

配套：客户端「重置基线」按钮（删 `.cheese-tiger-version`），清单校验失败的用户
一键转全量重建，与 FuyaoRime 的版本标记逃生门等价。

## 4. 通用更新框架与增量技术（已回收，30+ 条）

### 4.1 建议采纳（A 系列）

- **A1 文件级 SHA256 清单（ostree manifest）**：发版附全量运行文件的 path/sha256/size 清单，
  客户端核对本地、缺哪个补哪个、落盘即验。= §3 设计的完整形态，把版本标记单点依赖消掉。
  https://ostreedev.github.io/ostree/introduction/ 难度：中
- **A2 增量绑定 from 基线指纹**：Sparkle delta 带 `sparkle:deltaFrom`，应用前校验补丁结果
  checksum，不干净一律回退全量——「增量失败永不阻塞更新」。我们已有回退通道，补前置校验。
  https://sparkle-project.org/documentation/delta-updates/ 难度：低-中
- **A3 基线改造探针**：Sparkle 2.3 用二进制大小/Locales 发现「魔改过安装」的机器直接跳过
  delta。Rime 目录魔改率高，可在 DELTA.json 放 2-3 个探针（tiger.schema.yaml 大小 + 主词典
  hash）做第一道便宜闸门。难度：低
- **A4 ed25519 签名**：私钥签 zip 与清单、公钥内置客户端；现在只有 zip 级 SHA256，
  防损坏不防篡改（`.sha256` 可被连着换）。Dart 验签用
  [cryptography](https://pub.dev/packages/cryptography)（活跃）或
  [ed25519_edwards](https://pub.dev/packages/ed25519_edwards)；发布侧 minisign CLI。难度：低
- **A5 manifest 签名 + 版本单调**：manifest 带版本号与 `generated_at`，客户端记录已见最高
  版本，更旧的警告（TUF targets 最小化）。难度：低-中
- **A6 文件级校验补充 zip 级**：部署完成后按 manifest 复核目标目录，日志报「N/M 文件一致」
  （Omaha/electron-updater 模式）。难度：低（依附 A1）
- **A7 GitHub API 条件请求**：ETag + If-None-Match，304 **不计入速率限制**；与 10 分钟缓存
  互补。https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api 难度：低
- **A8 版本比较换 `pub_semver`**（Dart 团队出品），处理 v 前缀/四段版本/预发布段。难度：低
- **A9 部署后自检**：「更新成功但打不出字」变成客户端主动发现（依附 A1）。难度：低
- **A10 「修复」动作**：清单比对 + 从缓存/远端补文件 + 部署；老底子存量用户一键救回。难度：中
- **A11 发布纪律**：每个 tag 必有 full zip + manifest +（可选）相对最老基线的 delta，
  全量永不删除（Sparkle generate_appcast / Squirrel releasify 都这样）。难度：低

### 4.2 简化采纳（B 系列）

- **B1 TUF 五角色 → 两级**：root 公钥内置（离线长期）+ 发布机私钥签 manifest；
  manifest 加 `valid_until`，过期警告但 fail-open（个人项目不能锁死自己）。难度：低
- **B2 回滚保护**：持久化 `last_seen_manifest_version`，更旧的清单标警告。难度：低
- **B3 换 key 用新旧双签过渡**（丢 key = 老安装永远收不到更新，Tauri 明言）。难度：低-中
- **B4 灰度**：manifest 放 `rollout_percent`，客户端用持久化随机设备 ID 取模决定提示与否；
  手动检查绕过（Sparkle phasedRollout 的零服务端版）。难度：低
- **B5 关键更新标记**：`critical_below: "0.3.24"`——打不出字这类事故的正式出口，
  命中版本弹不可关闭的强提示。难度：低
- **B6 渠道**：stable/beta 直接用 GitHub prerelease 承载，设置里选渠道读不同 Release。难度：低
- **B7 binary_patch（bsdiff+zstd，纯 Dart）先基准后 vendor**：设计对路（补丁内嵌三重
  SHA256、Isolate、MIT、无 FFI）但太新（1.0.0、2 commits、0 star、120 下载）。bsdiff
  create 需 `max(17n,9n+m)` 内存、apply 需 `n+m`——300MB 模型 bin 客户端要 600MB 内存，
  **大 bin 不适用**；1-10MB 词典/yaml 非常适合。先在方案仓库跑真实 round-trip + fuzz。
  https://pub.dev/packages/binary_patch 难度：中
- **B8 zstd 零新依赖**：`archive` 3.6.x 自带纯 Dart `ZstdEncoder/Decoder`——增量资产换
  zstd-19，模型/词典重复内容多时优于 deflate。难度：低
- **B9 大模型 bin 用 CDC 分块**（casync/FastCDC 简化版）：滚动 hash 切 1-8MB 块、按块 hash
  建清单、客户端只拉缺块，内存只与块大小相关；与 A1 清单天然同构。难度：中-高
- **B10 退一步用固定块 + HTTP Range**：manifest 附 4MB 块 sha256 表，miss 的块发 Range
  （GitHub asset CDN 支持 Range，需实测）。难度：中
- **B11 自更新维持不做**：三平台自更新攻击面/维护面不划算；补「检查到自身新版本 → 展示
  更新日志 + 打开 Releases 页」即可。若将来做，严格走验签→暂存→备份→替换→启动校验。
  https://blog.doyensec.com/2026/02/16/electron-safe-updater.html 难度：低（提示跳转）
- **B12 签名失败必须硬失败**：不留「跳过验证继续装」的口子；`.sha256` 缺失视为异常。难度：低
- **B13 强制更新 fail-open**：「启动不联网」红线下只做「检查时评估」的软提示（B5），
  不做启动阻断。难度：低

### 4.3 不适用但留档（C 精选）

- Sparkle appcast RSS 全家桶：不迁移，但清单字段结构对照它设计；feed 连 release notes 一起签
- Squirrel 的反面教材：delta 失败**静默**回退全量——我们的回退必须写日志
- Courgette/Zucchini：只对机器码有意义，方案包是数据文件，bsdiff 已够
- xdelta3：pub.dev 无 Dart 移植，FFI 违背纯 Dart 约束
- Sigstore/Uptane/casync/Nix：基础设施过重，各取一个思想（签名可审计 / 决策与镜像分离 /
  元数据分离防误报 / narinfo 三元组形状）
- **清单 hash 只算内容、mtime 不参与**（casync 教训，避免 touch 即误报）

### 4.4 Dart 生态核实小结

| 需求 | 结论 |
|---|---|
| bsdiff 纯 Dart | binary_patch 1.0.0——先基准测试再 vendor（MIT 允许） |
| xdelta | 无 Dart 移植 |
| zstd | **`archive`（已有依赖）自带纯 Dart 实现，零新依赖** |
| ed25519 | cryptography（推荐）/ ed25519_edwards |
| semver | pub_semver（Dart 团队） |
| HTTP 条件请求 | 手写 ETag header 即可 |

**优先级排序**：A1+A9+A10（清单与修复）> A2+A3（增量绑定基线）> A4+A5+B1/B2（签名与
回滚保护）> A7/A8（省额度、版本处理）> B8（zstd）> B4/B5/B6（灰度/关键更新/渠道）>
B7（bsdiff 验证）> B9/B10（大文件分块，先把 A1 跑顺）。

## 5. 前端部署自动化与 GitHub 加速（已回收，本机实测 30 条）

**部署接口（源码级 + 本机实测核实）**：

| 前端 | 正确姿势 | 验证方法 |
|---|---|---|
| fcitx5(mac) | **POST** `fcitx5-curl /config/addon/rime/deploy -X POST -d '{}'`——源码链路 setSubConfig("deploy") → 完整 librime 重启；响应恒为 200 空体（fire-and-forget） | build/*.yaml mtime 轮询 + `/tmp/Fcitx5.log`（本机已实测部署生效） |
| 元书 Cobra | **有官方 CLI**（本机实测）：`"/Library/Input Methods/Cobra.app/Contents/MacOS/Cobra" deploy`（还有 `sync` / `register` / `print`，print 可探测用户目录权威路径），exit code 判成败；killall 退役 | exit code + build mtime |
| 鼠须管 | `Squirrel --reload`（已是最优）；另有 `--sync` | `$TMPDIR/rime.squirrel.ERROR` 扫描 |
| 小狼毫 | `WeaselDeployer /deploy` + `/sync`（sync 可接入云同步流程）；日志 `%TEMP%\rime.weasel` | `%APPDATA%\Rime\build` mtime + ERROR 日志 |
| 虎韵 | `Tigrime.Deployer.exe` stdout JSON `{"deployed":true,...}`——解析即得成败 | JSON 解析 |
| 同文 Trime | **官方广播** `am broadcast -a com.osfans.trime.action.DEPLOY`（2025-01 起，需 READ_INPUT_STATE 签名权限 → **Shizuku shell 能发**）| 轮询 build mtime（广播无返回值） |
| 仓(iOS) | `hamster://…?deploy` / `?sync` | 无法程序化验证 |

来源：fcitx5-beast / fcitx5-macos / fcitx5-rime 源码、https://fcitx-contrib.github.io/docs/im/rime.html 、
Trime PR #1570、Squirrel SKILL.md、Weasel changelog。fcitx5-remote 确认无部署命令（别再试）。
统一建议：写公共 `verifyDeploy(userDir, beforeMtimes, timeout)`，部署前快照 build mtime、
部署后轮询 + ERROR 日志扫描，给出人话结论。

**检查与下载加速**：

- ★ **`releases/latest` 302 探测**：HEAD 请求拿最新 tag，**0 API 调用**；tag 变了才调 API 拿资产列表——匿名 60/h 限额问题性价比最高的解法（本仓库实测可用）
- **确定性资产 URL**：命名规范已知的仓库可直接拼 `releases/download/<tag>/<asset>`，连 API 都不用
- **ETag 条件请求**：304 不计入限额但**仅限带 token 的请求**（官方文档原文）；ETag 按页缓存
- **CNB 镜像（cnb.cool，腾讯）**：snout 在用；release API 直接带 sha256 省一次校验文件下载；需仓库侧镜像流程
- **gh-proxy 系公共镜像**：频繁失效（ghproxy.com/ghp.ci 已死，现存 ghfast.top 等），不可写死——镜像列表放仓库纯文本定期拉取；SHA256 校验必须先于解包（现状已满足）；带 token 时禁止走第三方
- **自建 Cloudflare Workers**（hunshcn/gh-proxy，10 万请求/天免费）：个人长期方案最优
- jsDelivr：只服务 git 仓库文件（20MB 上限），发版 zip 不适用

**Dart 生态（pub.dev 核实）**：

- **socks_socket** 2.1.0：专为 `HttpClient.connectionFactory` 设计（Dart 3.5+），补齐 SOCKS5 缺口
- **background_downloader** 9.6.5（507 likes）：断点续传/暂停/网速显示，iOS/macOS 原生 URLSession 后台续传；备选手写 Range + `.part` 约 50 行
- **local_notifier**：更新完成系统通知；**tray_manager + launch_at_startup + window_manager**：托盘常驻三件套；**flutter_alone**：单实例 + 二次启动唤起
- version / pub_semver：版本比较去手写

**签名与公证**：

- **macOS 15.1 起右键打开已死**——README 引导话术必须改为「系统设置 → 隐私与安全性 → 仍要打开」或给 `xattr -r -d com.apple.quarantine` 命令（DMG 里放「首先阅读.txt」）
- Apple Developer $99/年含公证（notarytool + stapler 三条命令）
- Windows：Azure Trusted Signing $9.99/月但**个人仅限美加**；**Certum 开源证书 €49/年**（GPL-3.0 仓库符合，云签名可接进 Actions）；SignPath 对 OSS 有免费计划；无 EV 不再豁免 SmartScreen，OV 性价比更高

## 6. WebDAV 可靠性升级（已回收，28 条）

**P0（防丢数据）**：

1. **条件 PUT**：If-Match（上次 ETag）/ 首传 If-None-Match: *，412 → 冲突流程；弱 ETag（W/）不能用于 If-Match。RFC 4918 §8.6。webdav_client.dart 约 30 行——**「后写赢」的根治**，优先级最高
2. **冲突副本呈现**（Syncthing 模式）：确定性赢家 + 输家存 `<名>.conflict-<设备>-<时间>.<扩展名>`，UI 列冲突对，永不静默丢数据、永不自动合并
3. **版本向量**：manifest 每文件加 `rev: {deviceId: counter}`，并发判定不用 mtime（Syncthing 算法，200 行内可实现）
4. **429/503 统一退避**：Retry-After 优先，否则指数 + 抖动；**坚果云免费版 600 次/30 分钟（官方数字）**，串行 + 每请求 200ms 间隔
5. **重定向纪律**：Dart 只自动跟随 GET/HEAD 的 301——写类请求（PUT/PROPFIND/MKCOL）遇 301/302 报错提示改 https；307/308 才原方法重发（避免凭据泄露 + 409 误判）
6. **错误码映射表**：401 凭据 / 403 停止重试 / 405 已存在（MKCOL 算成功）/ 409 父目录缺失（自动补建）/ 412 冲突 / 423 锁定跳过不中断（Nextcloud files_lock 常见）/ 429 退避 / 507 空间满

**P1（稳态对账）**：

7. **按 kind 打 zip 上传**：请求数从几十降到 1，绕开坚果云 750 项分页；顺带可整体加密（AES-256-GCM + PBKDF2，pointycastle，默认关闭——custom_phrase 等敏感文件不该明文上第三方盘）
8. **PROPFIND Depth 1 对账**：manifest 与云端实况比对（防网页端手删/断网残留的幻影文件）；坚果云禁 infinity，只用 0/1
9. **坚果云文件名预检**：255 字符、`\ / : * ? " > < |`、`tmp`/`lock` 开头禁止；每段 RFC 3986 严格编码
10. **401 定制提示**：坚果云必须应用密码、InfiniCLOUD 要勾「允许外部应用连接」
11. **版本保留**：按文件进 `<appSupport>/sync-versions/<日期>/`（Syncthing simple 策略），替代全量前备份
12. **群晖无 ETag 回退**：mtime+size+sha 三元组比较（rclone 先例）
13. **NFC 归一化**：macOS NFD vs 其他平台 NFC，带调拼音文件名隐形分叉——路径进同步库前统一 NFC（unorm_dart）
14. **Nextcloud profile**：探测后启用 X-OC-Mtime（保 mtime）、识别 chunking v2（仅当真有 >50MB 需求）
15. **服务端 profile 机制**（rclone `--webdav-vendor` 先例）：{supportsEtag, supportsLock, maxListPage, rateLimit} 集中一处，auto 由 OPTIONS 探测（DAV: 头）
16. **`.syncignore`**（gitignore 语法 + `!` 反选 + 随库分发）统一 shouldCopy 白名单与用户排除
17. **下载预演**：将覆盖 / 将新增 / 云端独有三栏确认（dotdrop compare 思想）
18. **custom.yaml 键级三方合并**（祖先版 + 云端 + 本机按 YAML 顶层键合并）——放最后

**关键数字（坚果云官方核实）**：免费 600 req/30min（付费 1500）；月流量上传 1GB / 下载 3GB；单文件 500MB；列目录 750 项分页；必须应用密码。

**明确不做**：客户端主动 LOCK（制造 423 互相伤害）、CRDT 全量改造、socks5 走同步（与主客户端共用代理即可）。

## 7. 与已知痛点的映射（AGENTS「下一步」清单）

| 已知痛点 | 对应调研条目 |
|---|---|
| 0.3.24 事故（基线漂移/缺文件） | §3 设计草案、§4.A1/A2/A3 探针、A9 部署后自检、A10 修复动作 |
| 云同步 301/409、冲突 | §2.1-13/14、§1.4 原生快照合并（词库）+ §6 P0 条件 PUT/冲突副本（配置文件） |
| Dart 不支持 socks5 | §5 socks_socket（HttpClient.connectionFactory，Dart 3.5+） |
| 不做自动自更新 | §4.B11 维持决策补提示跳转、§2.1-29 包管理器分发 |
| 显示落后版本数 / 失败重试 | §2.1-7 退避重试、§4.A7 ETag 省额度、§0 P1 |
| backup_userdata.py 的 Dart 重做 | §2.1-13/14 原生 sync 快照（可能不再需要整包备份）；fcitx5 `--sync`/`/sync`、Cobra sync、Trime SYNC_USER_DATA 广播均已核实可触发 |
| 签名与公证 | §4.A4 ed25519 验签、§5 Certum €49/年（开源证书）/ Apple $99 含公证 |
| Windows 回滚实跑 / macOS 实跑更新 | 发版 v0.10 后随真实新版本验证；部署验证函数（§5 表格）让回滚成败可自动判定 |
