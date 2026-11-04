# 芝士虎整更新器（Scripting / iOS）

在 iPhone / iPad 上用 [Scripting](https://scripting.fuqiuluo.com/) 运行的轻量更新器：
检查芝士虎整最新 Release → 下载增量包 → 解压 → 写入仓输入法（Hamster）或元书的
Rime 用户目录 → 请求输入法重新部署。

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

- 「设为当前」：决定「安装到当前目录」写入哪个
- 「重命名」：修改显示名称
- 「部署方式」：在 仓输入法 / 元书 / 手动 之间循环切换
- 「移除」：只从列表移除，不删手机上的实际文件

如果有多个目录，可以点「安装到全部目录」，一次更新所有目录并按各自的部署方式部署。

## 4. 更新流程

1. 点「检查更新」：读取 `viui798/viui-tiger-sentense` 的最新 Release，
   日志会显示版本与选中的资产（优先 `*-update.zip`）。
2. 点「安装到当前目录」或「安装到全部目录」：
   - 下载增量包到临时目录（走 Scripting 的后台下载，带进度条）；
   - 用 `FileManager.unzip` 解压；
   - 自动去掉增量包的 `update/` 前缀；
   - 只复制方案文件，跳过 `user.yaml`、`installation.yaml`、`reverse_freq.txt`、
     `custom_phrase.txt`、`*.userdb`、`*.options.yaml`、`*.log`、`*.md`、`build/`、`sync/`；
   - 覆盖前把旧文件备份到 `<Rime 目录>/.cheese-tiger-backup/<时间戳>/`（超过 32MB 不备份）；
   - 更新日志逐行显示复制了哪些文件。
3. 部署方式：
   - 每个目录可以在列表里单独设置，默认按路径自动推断（含 Hamster3 / 元书 → 元书）
   - 仓输入法 → 打开 `hamster://dev.fuxiao.app.hamster/rime?deploy`
   - 元书 → 打开 `hamster3://dev.fuxiao.app.hamster3/rime?action=deploy`
   - 手动 → 自己到输入法里点部署
4. 回到输入法确认候选正常。想回滚时，去「文件」里把
   `.cheese-tiger-backup/<时间戳>/` 下的文件拷回 Rime 目录。

## 5. 代码结构

| 文件 | 作用 |
|---|---|
| `script.json` | Scripting 脚本元信息、图标、远程更新地址 |
| `index.tsx` | 界面：目录选择、检查、安装、部署方式、日志 |
| `utils/github.ts` | 调 GitHub API，优先选 `-update.zip`，没有则选完整包 |
| `utils/install.ts` | 下载、解压、去 `update/` 前缀、过滤个人数据、备份、复制 |
| `utils/deploy.ts` | 用 `hamster://` / `hamster3://` 请求部署 |
| `utils/runtime.tsx` 等 | 从 Scripting 社区项目复用的文件与下载兼容层（MIT） |

## 6. 常见问题

- **选不了目录 / 提示不支持**：Scripting 版本太旧，升级后再试。
- **GitHub 限流**：匿名 API 每小时 60 次（按出口 IP）。等一段时间再点检查；
  脚本内部预留了 token 字段，但界面暂未提供输入框。
- **部署 URL 没反应**：把部署方式切到「手动」，在仓 / 元书里手动点部署。
- **看不到 Hamster/Rime 目录**：先启动一次仓输入法；或在「文件」App 里
  浏览 `我的 iPhone/Hamster` 确认目录存在。
- **安装后没变化**：确认部署方式选对；元书与仓的部署 URL 不同。

## 7. 限制

- 优先增量包；没有增量包时会下载完整包（较大）。
- **不会执行 `DELTA.json` 里的删除列表**（Windows / macOS / Android 客户端会执行）。
  发版删除文件时，iOS 需要手动清理一次。
- 不写 `.cheese-tiger-version`，安装版本记录在 Scripting 的本地存储里。
- 只在 iOS 上运行；桌面端请用 `app/` 里的 Flutter 客户端。
- 尚未在真机 / Scripting App 验证，首次使用如遇报错请把日志发回。

## 致谢

`utils/runtime.tsx`、`common.tsx`、`fs.tsx`、`downloader.tsx` 改编自
[BlackCCCat/Scripting-Scripts](https://github.com/BlackCCCat/Scripting-Scripts)（MIT License），
保留了其文件与下载工具的兼容处理。
