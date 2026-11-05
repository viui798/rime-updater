import {
  Button,
  HStack,
  Image,
  List,
  Menu,
  Navigation,
  NavigationLink,
  NavigationStack,
  ProgressView,
  Section,
  Spacer,
  TabView,
  Text,
  VStack,
  useEffect,
  useState,
} from "scripting"

import { basename } from "./utils/common"
import {
  inferMethod,
  loadConfig,
  loadPassword,
  methodLabel,
  persistPassword,
  saveConfig,
  type Config,
  type DirEntry,
} from "./utils/config"
import { deployInputMethod, type InputMethod } from "./utils/deploy"
import {
  checkScriptUpdate,
  openScriptPage,
  type SelfUpdateInfo,
} from "./utils/self_update"
import { list } from "./utils/fs"
import {
  DEFAULT_REPO,
  fetchLatest,
  parseRepo,
  type ReleaseAsset,
  type ReleaseInfo,
} from "./utils/github"
import {
  downloadAsset,
  inferVersionFromName,
  installZip,
  listBackups,
  planZip,
  removeBackup,
  restoreBackup,
  stageLocalZip,
  type BackupEntry,
} from "./utils/install"
import { switchScheme, backupUserData } from "./utils/switch_scheme"
import {
  deleteCloudFiles,
  fetchLibrary,
  pullLibrary,
  pushFiles,
  syncKey,
  SYNC_ROOT,
  type SyncFile,
} from "./utils/sync_service"
import { createClient, isClientReady, type WebDavClient } from "./utils/webdav"
import {
  BackupsPage,
  CloudSyncPage,
  KvRow,
  LogPage,
  SettingsPage,
  SwitchSchemePage,
} from "./ui/pages"

console.log("[cheese-tiger] script loaded")

function releaseSnippet(body: string): string {
  return body
    .replace(/\r/g, "")
    .split("\n")
    .filter((line) => line.trim())
    .slice(0, 5)
    .join("\n")
}

function MainView() {
  const dismiss = Navigation.useDismiss()
  const [config, setConfig] = useState<Config>(loadConfig())
  const [password, setPassword] = useState<string>(loadPassword())
  const [remote, setRemote] = useState<ReleaseInfo | null>(null)
  const [busy, setBusy] = useState(false)
  const [percent, setPercent] = useState(0)
  const [log, setLog] = useState("")
  const [files, setFiles] = useState<string[]>([])
  const [backups, setBackups] = useState<BackupEntry[]>([])
  const [cloudFiles, setCloudFiles] = useState<SyncFile[]>([])
  const [cloudDevices, setCloudDevices] = useState(0)
  const [selfUpdate, setSelfUpdate] = useState<SelfUpdateInfo | null>(null)
  const [checkingSelf, setCheckingSelf] = useState(false)

  const activeDir =
    config.dirs.find((dir) => dir.id === config.activeId) ?? config.dirs[0]
  const installedVersion = activeDir
    ? config.installedVersions[activeDir.id] ?? ""
    : ""

  const status = !remote
    ? { text: "未检查", color: "secondaryLabel" }
    : installedVersion === remote.version
      ? { text: "已最新", color: "systemGreen" }
      : { text: "可更新", color: "systemOrange" }
  const progressText = busy
    ? percent > 0
      ? `下载 ${Math.round(percent * 100)}%`
      : "处理中…"
    : ""

  function append(line: string) {
    setLog((previous) => (previous ? `${previous}\n${line}` : line))
  }

  const selfUpdateLabel = selfUpdate
    ? selfUpdate.hasUpdate
      ? `有新版本 v${selfUpdate.latest}，当前 v${selfUpdate.current}`
      : `已是最新（v${selfUpdate.current}）`
    : ""

  async function checkSelfUpdate() {
    if (checkingSelf) return
    setCheckingSelf(true)
    try {
      const info = await checkScriptUpdate()
      setSelfUpdate(info)
      append(
        info.hasUpdate
          ? `脚本有新版本：v${info.current} → v${info.latest}`
          : `脚本已是最新 v${info.current}`,
      )
      const DialogApi: any = (globalThis as any).Dialog
      if (info.hasUpdate) {
        let go = true
        if (DialogApi?.confirm) {
          go = await DialogApi.confirm({
            title: "发现新脚本版本",
            message: `当前 v${info.current}，最新 v${info.latest}。\n\n在 Scripting 中打开脚本页面即可检查 / 重新导入，脚本本身也会每 24 小时自动检查一次。`,
            confirmLabel: "打开脚本页面",
            cancelLabel: "稍后",
          })
        }
        if (go) await openScriptPage(info.url)
        return
      }
      const message = `当前 v${info.current}，已是最新。`
      if (DialogApi?.alert) {
        await DialogApi.alert({ title: "检查脚本更新", message, buttonLabel: "好" })
      } else if (DialogApi?.confirm) {
        await DialogApi.confirm({
          title: "检查脚本更新",
          message,
          confirmLabel: "好",
          cancelLabel: "关闭",
        })
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      append(`检查脚本更新失败：${message}`)
      const DialogApi: any = (globalThis as any).Dialog
      if (DialogApi?.alert) {
        await DialogApi.alert({ title: "检查脚本更新失败", message, buttonLabel: "好" })
      }
    } finally {
      setCheckingSelf(false)
    }
  }

  function updateConfig(next: Config) {
    setConfig(next)
    saveConfig(next)
  }

  function setActive(id: string) {
    updateConfig({ ...config, activeId: id })
    void refreshBackups(config.dirs.find((dir) => dir.id === id))
    void refreshCloud(config.dirs.find((dir) => dir.id === id))
  }

  async function resolveTarget(dir: DirEntry): Promise<string> {
    const fm: any = (globalThis as any).FileManager
    if (dir.bookmarkName && typeof fm?.bookmarkedPath === "function") {
      try {
        const resolved = await fm.bookmarkedPath(dir.bookmarkName)
        if (resolved) return String(resolved)
      } catch {}
    }
    return dir.path
  }

  /**
   * 从磁盘读回各目录的已装版本。
   *
   * 之前版本只在「本脚本安装成功」后写内存配置，从没读过盘上的标记文件，
   * 所以用户自己放进去（或别的端装的）目录一律显示「未知 / 不显示版本」。
   */
  async function refreshVersions() {
    if (config.dirs.length === 0) return
    const next = { ...config.installedVersions }
    let changed = false
    for (const dir of config.dirs) {
      try {
        const target = await resolveTarget(dir)
        if (!target) continue
        const version = await readInstalledVersion(target)
        if (!version) continue
        if (next[dir.id] !== version) {
          next[dir.id] = version
          changed = true
        }
      } catch {
        // 单个目录读失败不影响其它目录
      }
    }
    if (changed) updateConfig({ ...config, installedVersions: next })
  }

  async function refreshFiles() {
    const dir = activeDir
    if (!dir) {
      setFiles([])
      return
    }
    try {
      const target = await resolveTarget(dir)
      const entries = await list(target)
      setFiles(
        entries
          .filter((name) => name && name !== "." && name !== "..")
          .sort((a, b) => a.localeCompare(b)),
      )
    } catch (error: any) {
      setFiles([])
      append(`无法读取目录：${String(error?.message ?? error)}`)
    }
  }

  async function refreshBackups(dir?: DirEntry) {
    const targetDir = dir ?? activeDir
    if (!targetDir) {
      setBackups([])
      return
    }
    try {
      const target = await resolveTarget(targetDir)
      setBackups(await listBackups(target))
    } catch (error: any) {
      setBackups([])
      append(`读取备份失败：${String(error?.message ?? error)}`)
    }
  }

  function syncClient(): WebDavClient {
    return createClient(config.syncUrl, config.syncUser, password)
  }

  function deviceIdNow(): string {
    if (config.deviceId) return config.deviceId
    const id = `ios-${Date.now()}`
    updateConfig({ ...config, deviceId: id })
    return id
  }

  function deviceNameNow(): string {
    return (config.deviceName || "iPhone").trim() || "iPhone"
  }

  async function refreshCloud(dir?: DirEntry) {
    const targetDir = dir ?? activeDir
    const client = syncClient()
    if (!isClientReady(client)) {
      setCloudFiles([])
      setCloudDevices(0)
      return
    }
    const kind = syncKey(targetDir?.inputMethod ?? "hamster")
    const library = await fetchLibrary(client, kind)
    setCloudFiles(library.files)
    setCloudDevices(library.devices.length)
  }

  function saveSyncConfig() {
    const next = {
      ...config,
      syncUrl: config.syncUrl.trim().replace(/\/+$/, ""),
      syncUser: config.syncUser.trim(),
      deviceName: deviceNameNow(),
    }
    updateConfig(next)
    persistPassword(password)
    append("云同步配置已保存")
  }

  async function uploadCloud() {
    if (busy) return
    const dir = activeDir
    if (!dir) {
      append("请先添加一个 Rime 用户目录。")
      return
    }
    const client = syncClient()
    if (!isClientReady(client)) {
      append("请先填写 WebDAV 地址。")
      return
    }
    const DialogApi: any = (globalThis as any).Dialog
    if (DialogApi?.confirm) {
      const ok = await DialogApi.confirm({
        title: "上传本机",
        message: `把「${dir.name}」的个人数据上传到云端同步库？同名文件会覆盖云端。`,
        confirmLabel: "上传",
        cancelLabel: "取消",
      })
      if (!ok) return
    }
    setBusy(true)
    setPercent(0)
    try {
      saveSyncConfig()
      const kind = syncKey(dir.inputMethod)
      const target = await resolveTarget(dir)
      append(`[${dir.name}] 上传个人数据到 ${SYNC_ROOT}/${kind}/files`)
      const result = await pushFiles({
        client,
        kind,
        target,
        deviceId: deviceIdNow(),
        deviceName: deviceNameNow(),
        log: append,
      })
      append(`[${dir.name}] 已上传 ${result.uploaded} 个文件`)
      await refreshCloud()
    } catch (error: any) {
      append(`✗ 上传失败：${String(error?.message ?? error)}`)
    } finally {
      setBusy(false)
      setPercent(0)
    }
  }

  async function downloadCloud() {
    if (busy) return
    const dir = activeDir
    if (!dir) {
      append("请先添加一个 Rime 用户目录。")
      return
    }
    const client = syncClient()
    if (!isClientReady(client)) {
      append("请先填写 WebDAV 地址。")
      return
    }
    const DialogApi: any = (globalThis as any).Dialog
    if (DialogApi?.confirm) {
      const ok = await DialogApi.confirm({
        title: "下载云端",
        message: `把云端同步库写进「${dir.name}」？覆盖前会先备份本机个人数据。`,
        confirmLabel: "下载",
        cancelLabel: "取消",
      })
      if (!ok) return
    }
    setBusy(true)
    setPercent(0)
    try {
      saveSyncConfig()
      const kind = syncKey(dir.inputMethod)
      const target = await resolveTarget(dir)
      append(`[${dir.name}] 下载 ${SYNC_ROOT}/${kind}/files`)
      await pullLibrary({
        client,
        kind,
        target,
        log: append,
        backupLabel: `${dir.name}-同步前`,
        backup: async (label) => {
          await backupUserData(target, label, append)
        },
      })
      await deployDir(dir)
      await refreshCloud()
      await refreshFiles()
      append("云同步完成")
    } catch (error: any) {
      append(`✗ 下载失败：${String(error?.message ?? error)}`)
    } finally {
      setBusy(false)
      setPercent(0)
    }
  }

  async function refreshCloudList() {
    if (busy) return
    setBusy(true)
    try {
      await refreshCloud()
      append(`云端清单：${cloudFiles.length} 个文件`)
    } catch (error: any) {
      append(`✗ 读取云端清单失败：${String(error?.message ?? error)}`)
    } finally {
      setBusy(false)
    }
  }

  async function removeCloudFiles(files: SyncFile[]) {
    if (busy || files.length === 0) return
    const DialogApi: any = (globalThis as any).Dialog
    if (DialogApi?.confirm) {
      const label =
        files.length === 1
          ? files[0].path
          : `${files[0].path} 等 ${files.length} 个文件`
      const ok = await DialogApi.confirm({
        title: "删除云端文件",
        message: `从云端删除 ${label}？本机文件不受影响。`,
        confirmLabel: "删除",
        cancelLabel: "取消",
      })
      if (!ok) return
    }
    setBusy(true)
    try {
      const kind = syncKey(activeDir?.inputMethod ?? "hamster")
      await deleteCloudFiles({
        client: syncClient(),
        kind,
        paths: files.map((file) => file.path),
        log: append,
      })
      await refreshCloud()
    } catch (error: any) {
      append(`✗ 删除失败：${String(error?.message ?? error)}`)
    } finally {
      setBusy(false)
    }
  }

  async function registerDir(path: string, bookmarkName: string) {
    const existing = config.dirs.find((dir) => dir.path === path)
    if (existing) {
      setActive(existing.id)
      append(`这个目录已经在列表里：${existing.name}`)
      return
    }

    const DialogApi: any = (globalThis as any).Dialog
    const input = DialogApi?.prompt
      ? await DialogApi.prompt({
          title: "目录名称",
          message: "给这个 Rime 目录起个名字，例如「仓输入法」或「元书」。",
          defaultValue: basename(path) || "新目录",
          confirmLabel: "保存",
          cancelLabel: "取消",
        })
      : basename(path)
    const name = String(input ?? "").trim() || basename(path) || "Rime 目录"
    const dir: DirEntry = {
      id: `dir-${Date.now()}`,
      name,
      bookmarkName,
      path,
      inputMethod: inferMethod(path, name),
    }
    updateConfig({
      ...config,
      dirs: [...config.dirs, dir],
      activeId: dir.id,
    })
    append(`已添加目录：${name}（${methodLabel(dir.inputMethod)}部署）`)
  }

  /** 列出 Scripting 里已有的书签名称（拿不到就返回空集合）。 */
  async function existingBookmarkNames(): Promise<Set<string>> {
    const fm: any = (globalThis as any).FileManager
    try {
      const all: any = await fm?.getAllFileBookmarks?.()
      if (Array.isArray(all)) {
        return new Set(
          all
            .map((item: any) =>
              typeof item === "string"
                ? item
                : String(item?.name ?? item?.bookmarkName ?? ""),
            )
            .filter(Boolean),
        )
      }
      if (all && typeof all === "object") return new Set(Object.keys(all))
    } catch {
      // 拿不到就当作没有，后面仍会退到让用户自己命名
    }
    return new Set()
  }

  /**
   * Scripting 的 `pickDirectoryBookmark` 在不传 `preferredName` 时，
   * 会用「所选文件夹的名字」当书签默认名；一旦重名就弹改名框且确认键禁用，
   * 用户会卡在那里（同名文件夹早就被之前的尝试占用过）。
   * 这里主动给一个不重复的内部名，绕开那个对话框——界面上显示的名字
   * 由我们自己的「目录名称」输入框决定，与书签名无关。
   */
  function freshBookmarkName(taken: Set<string>): string {
    for (let i = 1; i <= 999; i += 1) {
      const candidate = `RimeUpdater-${i}`
      if (!taken.has(candidate)) return candidate
    }
    return `RimeUpdater-${Date.now()}`
  }

  async function pickFolder() {
    const picker: any = (globalThis as any).DocumentPicker
    if (typeof picker?.pickDirectoryBookmark !== "function") {
      append("当前 Scripting 版本不支持直接选择目录，请先升级 Scripting。")
      return
    }
    try {
      const taken = await existingBookmarkNames()
      const options = {
        preferredName: freshBookmarkName(taken),
        initialDirectory: activeDir?.path || undefined,
      }
      let result: any = null
      try {
        result = await picker.pickDirectoryBookmark(options)
      } catch {
        result = await picker.pickDirectoryBookmark()
      }
      if (!result) {
        append("已取消选择目录。")
        return
      }
      const path = String(result.path ?? "").trim()
      if (!path) return
      await registerDir(path, String(result.bookmarkName ?? ""))
    } catch (error: any) {
      const message = String(error?.message ?? error)
      append(`✗ 选择目录失败：${message}`)
      const DialogApi: any = (globalThis as any).Dialog
      void DialogApi?.alert?.({
        title: "无法选择目录",
        message: `${message}\n\n可以改用「手动输入路径」，或在「文件」App 里确认 Hamster/Rime 目录可见。`,
        confirmLabel: "知道了",
      })
    }
  }

  async function addManualPath() {
    const DialogApi: any = (globalThis as any).Dialog
    if (!DialogApi?.prompt) return
    const input = await DialogApi.prompt({
      title: "手动输入目录",
      message:
        "粘贴 Rime 目录的完整路径。可以先在「文件」App 里打开该目录确认路径。",
      defaultValue: activeDir?.path ?? "",
      confirmLabel: "添加",
      cancelLabel: "取消",
    })
    if (input == null) return
    const path = String(input).trim()
    if (!path) return
    try {
      await list(path)
    } catch (error: any) {
      void DialogApi?.alert?.({
        title: "路径不可用",
        message: `无法读取 ${path}\n${String(error?.message ?? error)}`,
        confirmLabel: "知道了",
      })
      return
    }
    await registerDir(path, "")
  }

  async function renameDir(dir: DirEntry) {
    const DialogApi: any = (globalThis as any).Dialog
    if (!DialogApi?.prompt) return
    const input = await DialogApi.prompt({
      title: "重命名目录",
      message: "输入新的名称。",
      defaultValue: dir.name,
      confirmLabel: "保存",
      cancelLabel: "取消",
    })
    if (input == null) return
    const name = String(input).trim()
    if (!name || name === dir.name) return
    updateConfig({
      ...config,
      dirs: config.dirs.map((item) => (item.id === dir.id ? { ...item, name } : item)),
    })
    append(`已重命名为：${name}`)
  }

  function setMethod(dir: DirEntry, method: InputMethod) {
    if (dir.inputMethod === method) return
    updateConfig({
      ...config,
      dirs: config.dirs.map((item) =>
        item.id === dir.id ? { ...item, inputMethod: method } : item,
      ),
    })
    append(`${dir.name} 部署方式：${methodLabel(method)}`)
  }

  async function removeDir(dir: DirEntry) {
    const DialogApi: any = (globalThis as any).Dialog
    if (DialogApi?.confirm) {
      const ok = await DialogApi.confirm({
        title: "删除目录",
        message: `从列表里移除「${dir.name}」？不会删除手机上的实际文件。`,
        confirmLabel: "移除",
        cancelLabel: "取消",
      })
      if (!ok) return
    }
    const dirs = config.dirs.filter((item) => item.id !== dir.id)
    const activeId =
      config.activeId === dir.id ? dirs[0]?.id ?? "" : config.activeId
    updateConfig({ ...config, dirs, activeId })
    append(`已移除目录：${dir.name}`)
  }

  async function editToken() {
    const DialogApi: any = (globalThis as any).Dialog
    if (!DialogApi?.prompt) return
    const input = await DialogApi.prompt({
      title: "GitHub Token",
      message: "可留空。填写后可以把匿名 API 限流从 60 次/小时提高到 5000 次/小时。",
      defaultValue: config.token,
      confirmLabel: "保存",
      cancelLabel: "取消",
    })
    if (input == null) return
    updateConfig({ ...config, token: String(input).trim() })
    append("Token 已保存")
  }

  async function editRepo() {
    const DialogApi: any = (globalThis as any).Dialog
    if (!DialogApi?.prompt) return
    const input = await DialogApi.prompt({
      title: "方案仓库",
      message: "填 owner/repo 或 GitHub 仓库网址，例如 viui798/viui-tiger-sentense。",
      defaultValue: config.repo,
      confirmLabel: "保存",
      cancelLabel: "取消",
    })
    if (input == null) return
    const repo = parseRepo(String(input))
    updateConfig({ ...config, repo, assetName: "" })
    setRemote(null)
    append(`方案仓库已改为：${repo}`)
  }

  function defaultAsset(release: ReleaseInfo): ReleaseAsset {
    return (
      release.assets.find((asset) => asset.name.endsWith("-update.zip")) ??
      release.assets[0]
    )
  }

  function resetRepo() {
    updateConfig({ ...config, repo: DEFAULT_REPO, assetName: "" })
    setRemote(null)
    append(`方案仓库恢复为 ${DEFAULT_REPO}`)
  }

  function pickAsset(name: string) {
    const asset = remote
      ? name
        ? remote.assets.find((item) => item.name === name)
        : defaultAsset(remote)
      : undefined
    updateConfig({ ...config, assetName: name })
    if (remote && asset) setRemote({ ...remote, chosen: asset })
    append(name ? `已选择安装包：${name}` : "已恢复自动选择安装包")
  }

  async function check() {
    if (busy) return
    setBusy(true)
    try {
      append(`检查 ${config.repo} 的远端版本…`)
      const release = await fetchLatest(config.token, config.repo, config.assetName)
      setRemote(release)
      append(`远端最新：v${release.version}（${release.chosen.name}）`)
    } catch (error: any) {
      append(`✗ ${String(error?.message ?? error)}`)
    } finally {
      setBusy(false)
    }
  }

  async function deployActive() {
    const dir = activeDir
    if (!dir) return
    await deployDir(dir)
  }

  async function deployDir(dir: DirEntry) {
    if (dir.inputMethod === "none") {
      append(`[${dir.name}] 请手动部署`)
      return
    }
    append(`[${dir.name}] 请求 ${methodLabel(dir.inputMethod)} 部署…`)
    try {
      await deployInputMethod(dir.inputMethod)
      append(`[${dir.name}] 已请求部署`)
    } catch (error: any) {
      append(`[${dir.name}] ✗ 部署失败：${String(error?.message ?? error)}`)
    }
  }

  async function prepareRemote(): Promise<ReleaseInfo> {
    const release = await fetchLatest(config.token, config.repo, config.assetName)
    setRemote(release)
    append(`远端最新：v${release.version}（${release.chosen.name}）`)
    return release
  }

  async function dryRun() {
    if (busy) return
    const targets = config.dirs.length > 1 ? config.dirs : activeDir ? [activeDir] : []
    if (targets.length === 0) {
      append("请先添加一个 Rime 用户目录。")
      return
    }
    setBusy(true)
    setPercent(0)
    try {
      const release = await prepareRemote()
      const zip = await downloadAsset(release.chosen, append, (progress) => {
        if (typeof progress.percent === "number") {
          setPercent(Math.max(0, Math.min(1, progress.percent)))
        }
      })
      for (const dir of targets) {
        const target = await resolveTarget(dir)
        if (!target) {
          append(`✗ ${dir.name}：找不到目录`)
          continue
        }
        append(`[${dir.name}] 预演 v${release.version} → ${target}`)
        const plan = await planZip(zip, target)
        append(
          `[${dir.name}] 将更新 ${plan.updated} 个，新增 ${plan.added} 个，跳过个人数据 ${plan.skipped} 个`,
        )
        for (const line of plan.files.slice(0, 20)) append(`[${dir.name}]   ${line}`)
        if (plan.files.length > 20) append(`[${dir.name}]   …其余 ${plan.files.length - 20} 个`)
      }
      append("预演完成（未写入任何文件）")
    } catch (error: any) {
      append(`✗ ${String(error?.message ?? error)}`)
    } finally {
      setBusy(false)
      setPercent(0)
    }
  }

  async function installToDirs(zip: string, version: string, targets: DirEntry[]) {
    const installedVersions = { ...config.installedVersions }
    for (const dir of targets) {
      const target = await resolveTarget(dir)
      if (!target) {
        append(`✗ ${dir.name}：找不到目录`)
        continue
      }
      append(`[${dir.name}] 安装到 ${target}`)
      // 单个目录失败不中断其它目录（基座不符时会抛错并提示改用完整包）。
      try {
        const result = await installZip(
          zip,
          target,
          version,
          append,
          installedVersions[dir.id] ?? "",
        )
        append(`[${dir.name}] 更新 ${result.copied} 个文件`)
        append(`[${dir.name}] 备份：${result.backupRoot}`)
        installedVersions[dir.id] = version
        await deployDir(dir)
      } catch (error: any) {
        append(`✗ ${dir.name}：${String(error?.message ?? error)}`)
      }
    }
    updateConfig({ ...config, installedVersions })
    await refreshBackups()
    append("全部完成")
  }

  async function installTargets(targets: DirEntry[]) {
    if (busy) return
    if (targets.length === 0) {
      append("请先添加一个 Rime 用户目录。")
      return
    }

    setBusy(true)
    setPercent(0)
    try {
      const release = remote ?? (await prepareRemote())
      if (!remote) setRemote(release)
      append(`准备安装 v${release.version} 到 ${targets.length} 个目录`)
      const zip = await downloadAsset(release.chosen, append, (progress) => {
        if (typeof progress.percent === "number") {
          setPercent(Math.max(0, Math.min(1, progress.percent)))
        }
      })
      await installToDirs(zip, release.version, targets)
    } catch (error: any) {
      append(`✗ ${String(error?.message ?? error)}`)
    } finally {
      setBusy(false)
      setPercent(0)
    }
  }

  function installAll() {
    return installTargets(config.dirs)
  }

  function installToDir(dir: DirEntry) {
    return installTargets([dir])
  }

  async function pickZip(): Promise<{ path: string; name: string } | null> {
    const picker: any = (globalThis as any).DocumentPicker
    if (typeof picker?.pickFiles !== "function") {
      append("当前 Scripting 版本不支持选择文件，请先升级 Scripting。")
      return null
    }
    const DialogApi: any = (globalThis as any).Dialog
    const picked = await picker.pickFiles({
      allowsMultipleSelection: false,
      shouldShowFileExtensions: true,
    })
    if (!picked || !picked.length) return null
    const zipName = basename(String(picked[0]))
    if (!zipName.toLowerCase().endsWith(".zip")) {
      void DialogApi?.alert?.({
        title: "只支持 zip",
        message: "请选择方案包里以 .zip 结尾的文件。",
        confirmLabel: "知道了",
      })
      return null
    }
    return { path: String(picked[0]), name: zipName }
  }

  async function installLocalZip() {
    if (busy) return
    const dir = activeDir
    if (!dir) {
      append("请先添加一个 Rime 用户目录。")
      return
    }
    const DialogApi: any = (globalThis as any).Dialog
    try {
      const zip = await pickZip()
      if (!zip) return
      const version = inferVersionFromName(zip.name) || "本地包"
      if (DialogApi?.confirm) {
        const ok = await DialogApi.confirm({
          title: "从本地 zip 安装",
          message: `将 ${zip.name} 安装到「${dir.name}」？覆盖前会生成快照备份。`,
          confirmLabel: "安装",
          cancelLabel: "取消",
        })
        if (!ok) return
      }
      setBusy(true)
      setPercent(0)
      append(`准备本地包 ${zip.name}（版本 ${version}）`)
      const staged = await stageLocalZip(zip.path)
      await installToDirs(staged, version, [dir])
      append("本地包安装完成")
    } catch (error: any) {
      append(`✗ ${String(error?.message ?? error)}`)
    } finally {
      setBusy(false)
      setPercent(0)
    }
  }

  async function runSwitch(zip: string, label: string, version: string) {
    const dir = activeDir
    if (!dir) {
      append("请先添加一个 Rime 用户目录。")
      return
    }
    const target = await resolveTarget(dir)
    append(`[${dir.name}] 换方案：${label}`)
    const result = await switchScheme(zip, target, dir.name, version, append)
    append(`[${dir.name}] 新方案写入 ${result.copied} 个文件`)
    append(`[${dir.name}] 个人数据备份：${result.backupRoot}`)
    updateConfig({
      ...config,
      installedVersions: { ...config.installedVersions, [dir.id]: version },
    })
    await deployDir(dir)
    await refreshBackups()
    await refreshFiles()
    append("换方案完成")
  }

  async function switchFromLocalZip() {
    if (busy) return
    const dir = activeDir
    if (!dir) {
      append("请先添加一个 Rime 用户目录。")
      return
    }
    const DialogApi: any = (globalThis as any).Dialog
    try {
      const zip = await pickZip()
      if (!zip) return
      if (DialogApi?.confirm) {
        const ok = await DialogApi.confirm({
          title: "换方案",
          message: `会用 ${zip.name} 替换「${dir.name}」的旧方案。个人数据会先备份、安装后恢复，输入法词库不受影响。`,
          confirmLabel: "开始",
          cancelLabel: "取消",
        })
        if (!ok) return
      }
      setBusy(true)
      setPercent(0)
      const version = inferVersionFromName(zip.name) || "本地包"
      const staged = await stageLocalZip(zip.path)
      await runSwitch(staged, zip.name, version)
    } catch (error: any) {
      append(`✗ 换方案失败：${String(error?.message ?? error)}`)
    } finally {
      setBusy(false)
      setPercent(0)
    }
  }

  async function switchFromRelease() {
    if (busy) return
    const dir = activeDir
    if (!dir) {
      append("请先添加一个 Rime 用户目录。")
      return
    }
    const DialogApi: any = (globalThis as any).Dialog
    if (DialogApi?.confirm) {
      const ok = await DialogApi.confirm({
        title: "换方案",
        message: `会用 ${config.repo} 的最新版本替换「${dir.name}」的旧方案。个人数据会先备份、安装后恢复。`,
        confirmLabel: "开始",
        cancelLabel: "取消",
      })
      if (!ok) return
    }
    setBusy(true)
    setPercent(0)
    try {
      const release = await prepareRemote()
      const zip = await downloadAsset(release.chosen, append, (progress) => {
        if (typeof progress.percent === "number") {
          setPercent(Math.max(0, Math.min(1, progress.percent)))
        }
      })
      await runSwitch(zip, release.chosen.name, release.version)
    } catch (error: any) {
      append(`✗ 换方案失败：${String(error?.message ?? error)}`)
    } finally {
      setBusy(false)
      setPercent(0)
    }
  }

  async function rollback(entry: BackupEntry) {
    if (busy) return
    const dir = activeDir
    if (!dir) return
    const DialogApi: any = (globalThis as any).Dialog
    if (DialogApi?.confirm) {
      const ok = await DialogApi.confirm({
        title: "回滚",
        message: `把 ${entry.name} 快照里的 ${entry.files} 个文件写回「${dir.name}」？当前文件会被覆盖。`,
        confirmLabel: "回滚",
        cancelLabel: "取消",
      })
      if (!ok) return
    }
    setBusy(true)
    try {
      const target = await resolveTarget(dir)
      append(`[${dir.name}] 回滚到 ${entry.name}`)
      const count = await restoreBackup(target, entry.path, append)
      append(`[${dir.name}] 已恢复 ${count} 个文件`)
      await deployDir(dir)
      await refreshBackups()
    } catch (error: any) {
      append(`✗ 回滚失败：${String(error?.message ?? error)}`)
    } finally {
      setBusy(false)
    }
  }

  async function deleteBackup(entry: BackupEntry) {
    if (busy) return
    const dir = activeDir
    if (!dir) return
    const DialogApi: any = (globalThis as any).Dialog
    if (DialogApi?.confirm) {
      const ok = await DialogApi.confirm({
        title: "删除备份",
        message: `删除快照「${entry.name}」？删除后无法再回滚到这一份。`,
        confirmLabel: "删除",
        cancelLabel: "取消",
      })
      if (!ok) return
    }
    try {
      await removeBackup(entry.path)
      append(`已删除备份：${entry.name}`)
      await refreshBackups()
    } catch (error: any) {
      append(`✗ 删除失败：${String(error?.message ?? error)}`)
    }
  }

  useEffect(() => {
    void refreshVersions()
    void refreshFiles()
    void refreshBackups()
    void refreshCloud()
    if (config.autoCheckOnLaunch) void check()
  }, [])

  const updaterTab = (
    <NavigationStack>
      <List
        navigationTitle="Rime 更新器"
        navigationBarTitleDisplayMode="inline"
        listStyle="insetGroup"
        toolbar={{
          cancellationAction: (
            <Button
              title="关闭"
              action={() => {
                dismiss()
              }}
            />
          ),
          primaryAction: (
            <Button
              title="检查"
              action={() => {
                void check()
              }}
              disabled={busy}
            />
          ),
        }}
      >
        <Section header={<Text>状态</Text>}>
          <KvRow label="当前目录" value={activeDir?.name ?? "未选择"} />
          {activeDir ? (
            <Text font="caption" foregroundStyle="secondaryLabel">
              {activeDir.path}
            </Text>
          ) : null}
          <KvRow
            label="已安装"
            value={installedVersion ? `v${installedVersion}` : "未知"}
          />
          <KvRow label="远端" value={remote ? `v${remote.version}` : "未检查"} />
          <KvRow label="状态" value={status.text} color={status.color} />
          {busy && percent > 0 ? (
            <ProgressView value={percent} total={1} progressViewStyle="linear" />
          ) : null}
          {progressText ? (
            <Text font="caption" foregroundStyle="secondaryLabel">
              {progressText}
            </Text>
          ) : null}
          {remote?.body ? (
            <Text font="caption" foregroundStyle="secondaryLabel">
              {releaseSnippet(remote.body)}
            </Text>
          ) : null}
        </Section>

        <Section
          header={<Text>更新</Text>}
          footer={
            config.dirs.length === 0 ? (
              <Text>还没有目录，下面的按钮大多是灰的。先到「目录」里添加一个 Rime 目录。</Text>
            ) : undefined
          }
        >
          <Button
            title="一键更新（全部目录）"
            buttonStyle="borderedProminent"
            action={() => void installAll()}
            disabled={busy || config.dirs.length === 0}
          />
          <HStack spacing={8}>
            <Button title="检查更新" action={check} disabled={busy} />
            <Button
              title="仅预演"
              action={dryRun}
              disabled={busy || config.dirs.length === 0}
            />
          </HStack>
          <HStack spacing={8}>
            <Button
              title="本地 zip 安装"
              action={installLocalZip}
              disabled={busy || !activeDir}
            />
            <Button
              title="部署当前"
              action={deployActive}
              disabled={busy || !activeDir}
            />
          </HStack>
        </Section>

        <Section
          header={<Text>目录</Text>}
          footer={<Text>点行末的 ⋮ 可以切换当前目录、改名、换部署方式或移除。</Text>}
        >
          {config.dirs.map((dir) => (
            <HStack key={dir.id}>
              <VStack alignment="leading" spacing={2}>
                <Text>
                  {dir.id === config.activeId ? `● ${dir.name}` : dir.name}
                </Text>
                <Text font="caption" foregroundStyle="secondaryLabel">
                  {`${methodLabel(dir.inputMethod)}${
                    config.installedVersions[dir.id]
                      ? ` · 已装 v${config.installedVersions[dir.id]}`
                      : " · 版本未知"
                  }`}
                </Text>
              </VStack>
              <Spacer />
              <Menu title={dir.name} systemImage="ellipsis.circle">
                <Button
                  title="设为当前"
                  action={() => setActive(dir.id)}
                  disabled={dir.id === config.activeId}
                />
                <Button title="重命名" action={() => renameDir(dir)} disabled={busy} />
                {config.dirs.length > 1 ? (
                  <Button
                    title="安装到此目录"
                    action={() => void installToDir(dir)}
                    disabled={busy}
                  />
                ) : null}
                <Menu title="部署方式">
                  <Button
                    title="仓输入法"
                    action={() => setMethod(dir, "hamster")}
                    disabled={dir.inputMethod === "hamster"}
                  />
                  <Button
                    title="元书"
                    action={() => setMethod(dir, "hamster3")}
                    disabled={dir.inputMethod === "hamster3"}
                  />
                  <Button
                    title="手动"
                    action={() => setMethod(dir, "none")}
                    disabled={dir.inputMethod === "none"}
                  />
                </Menu>
                <Button
                  title="移除目录"
                  role="destructive"
                  action={() => removeDir(dir)}
                  disabled={busy}
                />
              </Menu>
            </HStack>
          ))}
          {config.dirs.length === 0 ? (
            <Button
              title="添加目录"
              systemImage="plus"
              buttonStyle="borderedProminent"
              action={pickFolder}
              disabled={busy}
            />
          ) : null}
          <Menu
            label={
              <HStack>
                <Image systemName="plus" />
                <Text>添加目录</Text>
              </HStack>
            }
          >
            <Button title="选择目录" action={pickFolder} disabled={busy} />
            <Button title="手动输入路径" action={addManualPath} disabled={busy} />
          </Menu>
          {config.dirs.length === 0 ? (
            <Text font="caption" foregroundStyle="secondaryLabel">
              还没有目录。点「添加目录」选择仓输入法 / 元书的 Rime 文件夹。
            </Text>
          ) : null}
        </Section>
      </List>
    </NavigationStack>
  )

  const syncTab = (
    <NavigationStack>
      <CloudSyncPage
        busy={busy}
        hasDir={!!activeDir}
        config={config}
        password={password}
        cloudFiles={cloudFiles}
        cloudDevices={cloudDevices}
        onConfigChange={setConfig}
        onPasswordChange={setPassword}
        onSave={saveSyncConfig}
        onUpload={uploadCloud}
        onDownload={downloadCloud}
        onRefresh={refreshCloudList}
        onDeleteFiles={removeCloudFiles}
      />
    </NavigationStack>
  )

  const moreTab = (
    <NavigationStack>
      <List
        navigationTitle="更多"
        navigationBarTitleDisplayMode="inline"
        listStyle="insetGroup"
      >
        <Section header={<Text>数据与方案</Text>}>
          <NavigationLink
            destination={
              <BackupsPage
                busy={busy}
                hasDir={!!activeDir}
                backups={backups}
                onRollback={rollback}
                onDelete={deleteBackup}
                onRefresh={() => {
                  void refreshBackups()
                }}
              />
            }
          >
            <HStack>
              <Text>备份与回滚</Text>
              <Spacer />
              <Text font="caption" foregroundStyle="secondaryLabel">
                {`${backups.length} 份快照`}
              </Text>
            </HStack>
          </NavigationLink>
          <NavigationLink
            destination={
              <SwitchSchemePage
                busy={busy}
                hasDir={!!activeDir}
                activeDirName={activeDir?.name ?? ""}
                inputMethodLabel={activeDir ? methodLabel(activeDir.inputMethod) : "-"}
                repo={config.repo}
                onLocalZip={switchFromLocalZip}
                onRelease={switchFromRelease}
              />
            }
          >
            <HStack>
              <Text>换方案</Text>
              <Spacer />
              <Text font="caption" foregroundStyle="secondaryLabel">
                {activeDir ? activeDir.name : ""}
              </Text>
            </HStack>
          </NavigationLink>
          
          <NavigationLink
            destination={
              <LogPage
                log={log}
                verbose={config.verboseLog}
                filesCount={files.length}
                hasDir={config.dirs.length > 0}
                onToggleVerbose={(value: boolean) =>
                  updateConfig({ ...config, verboseLog: value })
                }
                onClear={() => setLog("")}
              />
            }
          >
            <HStack>
              <Text>日志</Text>
              <Spacer />
              <Text font="caption" foregroundStyle="secondaryLabel">
                {busy ? progressText || "处理中…" : ""}
              </Text>
            </HStack>
          </NavigationLink>
        </Section>
        <Section footer={<Text>同步与设置是独立页面，从底部导航进入。</Text>}>
          <HStack>
            <Text>当前目录</Text>
            <Spacer />
            <Text font="caption" foregroundStyle="secondaryLabel">
              {activeDir?.name ?? "未选择"}
            </Text>
          </HStack>
          <HStack>
            <Text>方案仓库</Text>
            <Spacer />
            <Text font="caption" foregroundStyle="secondaryLabel">
              {config.repo}
            </Text>
          </HStack>
        </Section>
      </List>
    </NavigationStack>
  )

  const settingsTab = (
    <NavigationStack>
      <SettingsPage
        busy={busy}
        config={config}
        remote={remote}
        onUpdate={updateConfig}
        onEditToken={editToken}
        onEditRepo={editRepo}
        onResetRepo={resetRepo}
        onPickAsset={pickAsset}
        selfUpdateLabel={selfUpdateLabel}
        onCheckSelfUpdate={() => {
          void checkSelfUpdate()
        }}
      />
    </NavigationStack>
  )

  return (
    <TabView>
      <VStack
        tabItem={
          <>
            <Image systemName="bolt.fill" />
            <Text>更新器</Text>
          </>
        }
        tag={1}
        frame={{ maxWidth: "infinity", maxHeight: "infinity" }}
      >
        {updaterTab}
      </VStack>
      <VStack
        tabItem={
          <>
            <Image systemName="cloud" />
            <Text>同步</Text>
          </>
        }
        tag={2}
        frame={{ maxWidth: "infinity", maxHeight: "infinity" }}
      >
        {syncTab}
      </VStack>
      <VStack
        tabItem={
          <>
            <Image systemName="square.grid.2x2" />
            <Text>更多</Text>
          </>
        }
        tag={3}
        frame={{ maxWidth: "infinity", maxHeight: "infinity" }}
      >
        {moreTab}
      </VStack>
      <VStack
        tabItem={
          <>
            <Image systemName="gearshape" />
            <Text>设置</Text>
          </>
        }
        tag={4}
        frame={{ maxWidth: "infinity", maxHeight: "infinity" }}
      >
        {settingsTab}
      </VStack>
    </TabView>
  )
}

async function run() {
  try {
    await Navigation.present({
      element: <MainView />,
      modalPresentationStyle: "overFullScreen",
    })
  } catch (error) {
    console.error("[cheese-tiger] 启动失败", error)
  }
}

run()
