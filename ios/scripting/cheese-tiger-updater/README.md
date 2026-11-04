# 芝士虎整更新器（Scripting / iOS）

在 iPhone / iPad 上用 [Scripting](https://scripting.fuqiuluo.com/) 运行的更新器：
检查方案仓库最新 Release → 下载增量包 → 解压 → 写入仓输入法（Hamster）或元书的
Rime 用户目录 → 请求输入法重新部署。

功能对齐桌面 / Android 客户端（除占用较大网络能力的功能外）：

| 功能 | iOS |
|---|---|
| 检查更新 | ✅ |
| 仅预演（只列将更新 / 新增的文件，不写盘） | ✅ |
| 一键更新（全部目录）/ 安装当前 | ✅ |
| 备份与回滚（快照列表、回滚、删除） | ✅ |
| 从本地 zip 安装 | ✅ `DocumentPicker.pickFiles` |
| 换方案向导（备份 → 清理 → 安装 → 恢复 → 部署） | ✅ |
| 任意 GitHub 方案（改仓库 + 选资产） | ✅ |
| 多目录、命名、重命名、部署方式、移除 | ✅ |
| 云同步（WebDAV）与同步库管理 | ⏳ 计划中（需确认 Scripting 的二进制上传能力） |

## 1. 安装 Scripting

在 App Store 搜索 **Scripting** 安装。需要较新的版本（要支持
`DocumentPicker.pickDirectoryBookmark` 与 `FileManager.unzip`，旧版会在日志里提示）。

## 2. 导入脚本

打开 Scripting → 添加 / 导入远程脚本 → 粘贴本文件夹的 GitHub 地址：

```
https://github.com/viui798/rime-updater/tree/main/ios/scripting/cheese-tiger-updater
```

Scripting 会读取 `script.json`，把 `index.tsx` 与 `utils/` 一起导入。
`script.json` 里带了 `remoteResource`，脚本可以按 24 小时自动检查自身更新。

## 3. 添加 Rime 目录（可多个）

点「添加目录」在「文件」App 里进入：

- 仓输入法：`我的 iPhone → Hamster → Rime`
- 元书：元书的 Rime 用户目录（如果「文件」里能看到）

选完会让您给目录起名字（例如「仓输入法」「元书」），书签会一起保存。
列表里每个目录都可以：

- 「设为当前」：决定「安装当前」写入哪个
- 「重命名」：修改显示名称
- 「部署方式」：在 仓输入法 / 元书 / 手动 之间循环切换
- 「移除」：只从列表移除，不删手机上的实际文件

## 4. 日常更新

1. 「检查更新」：读取当前仓库的最新 Release，日志显示版本与选中的资产。
2. 「仅预演」：下载包并解压到临时目录逐个比对，日志显示
   「将更新 N 个，新增 M 个，跳过个人数据 K 个」以及前 20 个文件名，**不写任何文件**。
3. 「一键更新」：按顺序安装到全部目录；「安装当前」只装当前目录。
4. 安装时：
   - 自动去掉增量包的 `update/` 前缀；
   - 只复制方案文件，跳过 `user.yaml`、`installation.yaml`、`reverse_freq.txt`、
     `custom_phrase.txt`、`*.userdb`、`*.options.yaml`、`*.log`、`*.md`、`build/`、`sync/`；
   - 覆盖前把旧文件备份到 `<Rime 目录>/.cheese-tiger-backup/<时间戳>/`，
     同目录的 `manifest.json` 记录版本、覆盖与新增的文件；
   - 超过 32MB 的文件只记录、不备份（与桌面端一致）。
5. 每个目录按自己的部署方式重新部署（仓 → `hamster://`，元书 → `hamster3://`，手动 → 自己点）。

## 5. 备份与回滚

「设置 → 备份与回滚」列出当前目录的全部快照（新 → 旧），显示版本与文件数：

- 「回滚」：把快照里备份的文件写回目录；快照里记录为「新增」的文件会被删除，
  然后请求部署。效果与桌面端回滚一致。
- 「删除」：删掉这一份快照（不可恢复）。

## 6. 从本地 zip 安装 / 换方案

- 「主页 → 本地 zip」：用系统文件选择框选一个 `.zip`，安装到当前目录，
  版本号从文件名推断（如 `cheese-tiger-v0.3.23-update.zip` → 0.3.23）。
- 「设置 → 换方案 → 从本地 zip 换方案」：适合换用其它方案包，
  会先把个人数据（`*.custom.yaml`、`*.userdb`、lua 统计等）备份到
  `<Rime>/.cheese-tiger-backup/switch-<时间戳>/`，清理旧方案运行文件
  （`lua/`、`opencc/`、`models/`、`dicts/` 等与根目录旧 yaml），
  安装新包，再把缺失的个人数据补回去，最后部署。
- 「从当前仓库换方案」：同上，但包来自设置的 GitHub 仓库最新 Release。

## 7. 任意 GitHub 方案

「设置 → 更新来源」可把仓库改成任意 `owner/repo` 或 GitHub 网址，例如
`viui798/viui-tiger-sentense`、`iDvel/rime-ice`。检查更新后，如果 Release 里有多个
zip，会在设置页列出资产，可点「选用」指定下载哪一个；默认优先 `-update.zip`。

## 8. 代码结构

| 文件 | 作用 |
|---|---|
| `script.json` | Scripting 脚本元信息、图标、远程更新地址 |
| `index.tsx` | 界面：主页 / 文件 / 设置三页，检查、预演、更新、本地 zip、换方案、备份回滚 |
| `utils/github.ts` | GitHub API：任意仓库、资产选择、版本解析 |
| `utils/install.ts` | 下载、解压、去 `update/` 前缀、过滤、快照与清单、预演、本地 zip、回滚 |
| `utils/switch_scheme.ts` | 换方案：收集 / 备份 / 清理 / 恢复个人数据 |
| `utils/deploy.ts` | 用 `hamster://` / `hamster3://` 请求部署 |
| `utils/runtime.tsx` 等 | 从 Scripting 社区项目复用的文件与下载兼容层（MIT） |

## 9. 常见问题

- **选不了目录 / 提示不支持**：Scripting 版本太旧，升级后再试。
- **GitHub 限流**：匿名 API 每小时 60 次（按出口 IP）。可在设置里填 Token。
- **部署 URL 没反应**：把部署方式切到「手动」，在仓 / 元书里手动点部署。
- **看不到 Hamster/Rime 目录**：先启动一次仓输入法；或在「文件」App 里
  浏览 `我的 iPhone/Hamster` 确认目录存在。
- **安装后没变化**：确认部署方式选对；元书与仓的部署 URL 不同。

## 10. 限制

- 不会执行 `DELTA.json` 里的删除列表（桌面 / Android 客户端会执行）。
  发版删除文件时，iOS 需要手动清理一次。
- 不写 `.cheese-tiger-version`，安装版本记录在 Scripting 的本地存储里。
- 云同步（WebDAV）尚未接入，暂时用桌面 / Android 端同步；接入后会共用同一云端结构
  `CheeseTigerSync/<kind>/files/`。
- 只在 iOS 上运行；桌面端请用 `app/` 里的 Flutter 客户端。

## 致谢

`utils/runtime.tsx`、`common.tsx`、`fs.tsx`、`downloader.tsx` 改编自
[BlackCCCat/Scripting-Scripts](https://github.com/BlackCCCat/Scripting-Scripts)（MIT License），
保留了其文件与下载工具的兼容处理。
