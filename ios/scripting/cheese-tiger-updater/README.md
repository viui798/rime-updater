# 芝士虎整更新器（Scripting / iOS）

在 iPhone / iPad 上用 [Scripting](https://scripting.fuqiuluo.com/) 运行的轻量更新器：
检查芝士虎整最新 Release → 下载增量包 → 解压 → 写入仓输入法（Hamster）或元书的
Rime 用户目录 → 请求输入法重新部署。

## 使用

1. 在 Scripting 里导入本文件夹（`ios/scripting/cheese-tiger-updater`）。
2. 第一次运行点「选择目录」，在「文件」App 里选：
   - 仓输入法：`我的 iPhone/Hamster/Rime`
   - 元书：元书的 Rime 用户目录（如果「文件」里能看到）
   选完后会保存书签，下次不用再选。
3. 点「检查更新」读取 `viui798/viui-tiger-sentense` 的最新 Release。
4. 点「下载并安装」：只更新方案文件，个人数据（`user.yaml`、`*.userdb`、
   `*.options.yaml` 等）不会被覆盖；被覆盖的旧文件会备份到
   `<Rime 目录>/.cheese-tiger-backup/<时间戳>/`。
5. 部署方式默认是仓输入法，调用 `hamster://…?deploy`；元书用 `hamster3://…`。

## 说明与限制

- 优先下载 `*-update.zip` 增量包；没有时用完整包。
- 增量包的 `update/` 前缀会自动去掉。
- **不会执行 `DELTA.json` 里的删除列表**（Windows / macOS / Android 客户端会执行）。
  如果发版删除了文件，iOS 上需要手动清理一次。
- 不写 `.cheese-tiger-version`，安装版本记录在 Scripting 的本地存储里。
- 只在 iOS 上运行；桌面端请用 `app/` 里的 Flutter 客户端。

## 致谢

`utils/runtime.tsx`、`common.tsx`、`fs.tsx`、`downloader.tsx` 改编自
[BlackCCCat/Scripting-Scripts](https://github.com/BlackCCCat/Scripting-Scripts)（MIT License），
保留了其文件与下载工具的兼容处理。
