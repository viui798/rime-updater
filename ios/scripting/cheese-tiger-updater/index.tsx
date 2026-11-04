import {
  Button,
  HStack,
  Image,
  List,
  Navigation,
  NavigationStack,
  Section,
  Spacer,
  TabView,
  Text,
  Toggle,
  Toolbar,
  ToolbarItem,
  VStack,
  useEffect,
  useState,
} from "scripting"

import { basename, storage } from "./utils/common"
import { deployInputMethod, type InputMethod } from "./utils/deploy"
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
  BACKUP_DIR,
  type BackupEntry,
} from "./utils/install"
import { switchScheme } from "./utils/switch_scheme"

console.log("[cheese-tiger] script loaded")

const CONFIG_KEY = "cheese_tiger_ios_config"

type DirEntry = {
  id: string
  name: string
  bookmarkName: string
  path: string
  inputMethod: InputMethod
}

type Config = {
  dirs: DirEntry[]
  activeId: string
  token: string
  installedVersions: Record<string, string>
  autoCheckOnLaunch: boolean
  verboseLog: boolean
  repo: string
  assetName: string
}

function normalizeMethod(value: any): InputMethod {
  return value === "hamster3" ? "hamster3" : value === "none" ? "none" : "hamster"
}

function normalizeConfig(data: any): Config {
  const dirs: DirEntry[] = []
  if (Array.isArray(data?.dirs)) {
    for (const item of data.dirs) {
      const path = String(item?.path ?? "").trim()
      if (!path) continue
      dirs.push({
        id: String(item?.id ?? path),
        name: String(item?.name ?? "").trim() || basename(path) || "Rime 目录",
        bookmarkName: String(item?.bookmarkName ?? ""),
        path,
        inputMethod: normalizeMethod(item?.inputMethod),
      })
    }
  }
  const installedVersions: Record<string, string> =
    data?.installedVersions && typeof data.installedVersions === "object"
      ? { ...data.installedVersions }
      : {}

  if (dirs.length === 0 && data?.path) {
    const path = String(data.path)
    const dir: DirEntry = {
      id: "dir-legacy",
      name: basename(path) || "我的 Rime",
      bookmarkName: String(data.bookmarkName ?? ""),
      path,
      inputMethod: normalizeMethod(data.inputMethod),
    }
    dirs.push(dir)
    if (data.installedVersion) installedVersions[dir.id] = String(data.installedVersion)
  }

  const activeId = dirs.some((dir) => dir.id === data?.activeId)
    ? String(data.activeId)
    : dirs[0]?.id ?? ""
  return {
    dirs,
    activeId,
    token: String(data?.token ?? ""),
    installedVersions,
    autoCheckOnLaunch: data?.autoCheckOnLaunch === true,
    verboseLog: data?.verboseLog !== false,
    repo: parseRepo(data?.repo),
    assetName: String(data?.assetName ?? ""),
  }
}

function loadConfig(): Config {
  try {
    const raw = storage()?.get?.(CONFIG_KEY)
    if (typeof raw === "string" && raw.trim()) {
      return normalizeConfig(JSON.parse(raw))
    }
  } catch {}
  return {
    dirs: [],
    activeId: "",
    token: "",
    installedVersions: {},
    autoCheckOnLaunch: false,
    verboseLog: true,
    repo: DEFAULT_REPO,
    assetName: "",
  }
}

function saveConfig(config: Config) {
  try {
    storage()?.set?.(CONFIG_KEY, JSON.stringify(config))
  } catch {}
}

function methodLabel(method: InputMethod): string {
  return method === "hamster3" ? "元书" : method === "none" ? "手动" : "仓输入法"
}

function inferMethod(path: string, name: string): InputMethod {
  const value = `${path} ${name}`.toLowerCase()
  if (value.includes("hamster3") || name.includes("元书")) return "hamster3"
  return "hamster"
}

function releaseSnippet(body: string): string {
  return body
    .replace(/\r/g, "")
    .split("\n")
    .filter((line) => line.trim())
    .slice(0, 10)
    .join("\n")
}

function KvRow(props: { label: string; value: string; color?: string }) {
  return (
    <HStack>
      <Text>{props.label}</Text>
      <Spacer />
      <Text foregroundStyle={props.color ?? "secondaryLabel"}>
        {props.value}
      </Text>
    </HStack>
  )
}

function MainView() {
  const dismiss = Navigation.useDismiss()
  const [config, setConfig] = useState<Config>(loadConfig())
  const [remote, setRemote] = useState<ReleaseInfo | null>(null)
  const [busy, setBusy] = useState(false)
  const [percent, setPercent] = useState(0)
  const [log, setLog] = useState("")
  const [files, setFiles] = useState<string[]>([])
  const [backups, setBackups] = useState<BackupEntry[]>([])

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

  function updateConfig(next: Config) {
    setConfig(next)
    saveConfig(next)
  }

  function setActive(id: string) {
    updateConfig({ ...config, activeId: id })
    void refreshBackups(config.dirs.find((dir) => dir.id === id))
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

  async function pickFolder() {
    const picker: any = (globalThis as any).DocumentPicker
    if (typeof picker?.pickDirectoryBookmark !== "function") {
      append("当前 Scripting 版本不支持直接选择目录，请先升级 Scripting。")
      return
    }
    try {
      let result: any = null
      try {
        result = await picker.pickDirectoryBookmark({
          initialDirectory: activeDir?.path || undefined,
        })
      } catch {
        // initialDirectory 失效时再试一次，不带初始目录
        result = await picker.pickDirectoryBookmark()
      }
      if (!result) return
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

  function cycleMethod(dir: DirEntry) {
    const nextMethod: InputMethod =
      dir.inputMethod === "hamster"
        ? "hamster3"
        : dir.inputMethod === "hamster3"
          ? "none"
          : "hamster"
    updateConfig({
      ...config,
      dirs: config.dirs.map((item) =>
        item.id === dir.id ? { ...item, inputMethod: nextMethod } : item,
      ),
    })
    append(`${dir.name} 部署方式：${methodLabel(nextMethod)}`)
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

  function selectAsset(asset: ReleaseAsset) {
    updateConfig({ ...config, assetName: asset.name })
    setRemote(remote ? { ...remote, chosen: asset } : remote)
    append(`已选择资产：${asset.name}`)
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
    if (dir.inputMethod === "none") {
      append("当前目录设置为手动部署")
      return
    }
    append(`请求 ${methodLabel(dir.inputMethod)} 部署…`)
    try {
      await deployInputMethod(dir.inputMethod)
      append("已请求部署")
    } catch (error: any) {
      append(`✗ 部署失败：${String(error?.message ?? error)}`)
    }
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
      const result = await installZip(zip, target, version, append)
      append(`[${dir.name}] 更新 ${result.copied} 个文件`)
      append(`[${dir.name}] 备份：${result.backupRoot}`)
      installedVersions[dir.id] = version
      await deployDir(dir)
    }
    updateConfig({ ...config, installedVersions })
    await refreshBackups()
    append("全部完成")
  }

  async function install(all: boolean) {
    if (busy) return
    const targets = all ? config.dirs : activeDir ? [activeDir] : []
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

  async function installLocalZip() {
    if (busy) return
    const dir = activeDir
    if (!dir) {
      append("请先添加一个 Rime 用户目录。")
      return
    }
    const picker: any = (globalThis as any).DocumentPicker
    if (typeof picker?.pickFiles !== "function") {
      append("当前 Scripting 版本不支持选择文件，请先升级 Scripting。")
      return
    }
    const DialogApi: any = (globalThis as any).Dialog
    try {
      const picked = await picker.pickFiles({
        allowsMultipleSelection: false,
        shouldShowFileExtensions: true,
      })
      if (!picked || !picked.length) return
      const zipName = basename(String(picked[0]))
      if (!zipName.toLowerCase().endsWith(".zip")) {
        void DialogApi?.alert?.({
          title: "只支持 zip",
          message: "请选择方案包里以 .zip 结尾的文件。",
          confirmLabel: "知道了",
        })
        return
      }
      const version = inferVersionFromName(zipName) || "本地包"
      if (DialogApi?.confirm) {
        const ok = await DialogApi.confirm({
          title: "从本地 zip 安装",
          message: `将 ${zipName} 安装到「${dir.name}」？覆盖前会生成快照备份。`,
          confirmLabel: "安装",
          cancelLabel: "取消",
        })
        if (!ok) return
      }
      setBusy(true)
      setPercent(0)
      append(`准备本地包 ${zipName}（版本 ${version}）`)
      const zip = await stageLocalZip(String(picked[0]))
      await installToDirs(zip, version, [dir])
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
    const picker: any = (globalThis as any).DocumentPicker
    if (typeof picker?.pickFiles !== "function") {
      append("当前 Scripting 版本不支持选择文件，请先升级 Scripting。")
      return
    }
    const DialogApi: any = (globalThis as any).Dialog
    try {
      const picked = await picker.pickFiles({
        allowsMultipleSelection: false,
        shouldShowFileExtensions: true,
      })
      if (!picked || !picked.length) return
      const zipName = basename(String(picked[0]))
      if (!zipName.toLowerCase().endsWith(".zip")) {
        void DialogApi?.alert?.({
          title: "只支持 zip",
          message: "请选择方案包里以 .zip 结尾的文件。",
          confirmLabel: "知道了",
        })
        return
      }
      if (DialogApi?.confirm) {
        const ok = await DialogApi.confirm({
          title: "换方案",
          message: `会用 ${zipName} 替换「${dir.name}」的旧方案。个人数据会先备份、安装后恢复，输入法词库不受影响。`,
          confirmLabel: "开始",
          cancelLabel: "取消",
        })
        if (!ok) return
      }
      setBusy(true)
      setPercent(0)
      const version = inferVersionFromName(zipName) || "本地包"
      const zip = await stageLocalZip(String(picked[0]))
      await runSwitch(zip, zipName, version)
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
    void refreshFiles()
    void refreshBackups()
    if (config.autoCheckOnLaunch) void check()
  }, [])

  const homeList = (
    <List
      navigationTitle="芝士虎整"
      navigationBarTitleDisplayMode="inline"
      listStyle="insetGroup"
      toolbar={
        <Toolbar>
          <ToolbarItem placement="topBarLeading">
            <Button action={dismiss}>
              <Image systemName="xmark.circle.fill" foregroundStyle="systemRed" />
            </Button>
          </ToolbarItem>
          <ToolbarItem placement="topBarTrailing">
            <Button
              title=""
              systemImage="questionmark.circle"
              action={() => {
                const DialogApi: any = (globalThis as any).Dialog
                void DialogApi?.alert?.({
                  title: "使用说明",
                  message:
                    "1. 在「设置」里添加 Rime 目录并命名。\n" +
                    "2. 点「检查更新」读取方案仓库最新版本。\n" +
                    "3. 想先确认文件时点「仅预演」，不会写盘。\n" +
                    "4. 点「一键更新」安装到全部目录，或「安装当前」。\n" +
                    "5. 安装 / 回滚后按各目录的部署方式重新部署。",
                  confirmLabel: "知道了",
                })
              }}
            />
          </ToolbarItem>
        </Toolbar>
      }
    >
      <Section header={<Text>本地信息</Text>}>
        <KvRow label="当前目录" value={activeDir?.name ?? "未选择"} />
        {config.dirs.length === 0 ? (
          <Text font="caption" foregroundStyle="secondaryLabel">
            还没有目录，请到「设置」页点「添加目录」。
          </Text>
        ) : null}
        {activeDir ? (
          <Text font="caption" foregroundStyle="secondaryLabel">
            {activeDir.path}
          </Text>
        ) : null}
        <KvRow
          label="已安装"
          value={installedVersion ? `v${installedVersion}` : "未知"}
        />
        <KvRow
          label="部署方式"
          value={activeDir ? methodLabel(activeDir.inputMethod) : "-"}
        />
      </Section>

      <Section header={<Text>状态</Text>}>
        <KvRow label="状态" value={status.text} color={status.color} />
        <KvRow
          label="远端"
          value={remote ? `v${remote.version}` : "未检查"}
        />
        {progressText ? <Text>{progressText}</Text> : null}
        {config.verboseLog ? (
          <Text font="caption" foregroundStyle="secondaryLabel">
            {log || "等待操作"}
          </Text>
        ) : null}
      </Section>

      <Section header={<Text>操作</Text>}>
        <HStack spacing={8}>
          <Button title="检查更新" action={check} disabled={busy} />
          <Button title="仅预演" action={dryRun} disabled={busy || config.dirs.length === 0} />
          <Button
            title="一键更新"
            action={() => install(true)}
            disabled={busy || config.dirs.length === 0}
          />
        </HStack>
        <HStack spacing={8}>
          <Button
            title="安装当前"
            action={() => install(false)}
            disabled={busy || !activeDir}
          />
          <Button
            title="部署当前"
            action={deployActive}
            disabled={busy || !activeDir}
          />
          <Button
            title="本地 zip"
            action={installLocalZip}
            disabled={busy || !activeDir}
          />
        </HStack>
      </Section>

      <Section header={<Text>远程信息</Text>}>
        <KvRow label="仓库" value={config.repo} />
        <KvRow label="版本" value={remote ? `v${remote.version}` : "未检查"} />
        <KvRow label="资产" value={remote?.chosen.name ?? "-"} />
        <KvRow
          label="发布"
          value={remote?.publishedAt ? remote.publishedAt.slice(0, 10) : "-"}
        />
      </Section>

      <Section header={<Text>更新说明</Text>}>
        <Text font="caption" foregroundStyle="secondaryLabel">
          {remote?.body ? releaseSnippet(remote.body) : "检查更新后显示"}
        </Text>
      </Section>
    </List>
  )

  const settingsList = (
    <List
      navigationTitle="设置"
      navigationBarTitleDisplayMode="inline"
      listStyle="insetGroup"
    >
      <Section header={<Text>目录</Text>}>
        {config.dirs.length === 0 ? (
          <Text foregroundStyle="secondaryLabel">
            还没有目录，点下面的「添加目录」，在「文件」里选择 Rime 用户目录。
          </Text>
        ) : null}
        {config.dirs.map((dir) => (
          <VStack key={dir.id} spacing={2}>
            <Text>{dir.id === config.activeId ? `● ${dir.name}` : dir.name}</Text>
            <Text font="caption" foregroundStyle="secondaryLabel">
              {dir.path}
            </Text>
            <Text font="caption" foregroundStyle="secondaryLabel">
              {`部署：${methodLabel(dir.inputMethod)}${
                config.installedVersions[dir.id]
                  ? ` · 已装 v${config.installedVersions[dir.id]}`
                  : ""
              }`}
            </Text>
            <HStack spacing={8}>
              <Button
                title="设为当前"
                action={() => setActive(dir.id)}
                disabled={dir.id === config.activeId || busy}
              />
              <Button title="重命名" action={() => renameDir(dir)} disabled={busy} />
              <Button title="部署方式" action={() => cycleMethod(dir)} disabled={busy} />
              <Button title="移除" action={() => removeDir(dir)} disabled={busy} />
            </HStack>
          </VStack>
        ))}
        <Button title="添加目录" action={pickFolder} disabled={busy} />
        <Button title="手动输入路径" action={addManualPath} disabled={busy} />
      </Section>

      <Section header={<Text>更新来源</Text>}>
        <KvRow label="仓库" value={config.repo} />
        <Button title="修改仓库" action={editRepo} disabled={busy} />
        <Button
          title="恢复默认仓库"
          action={() => {
            updateConfig({ ...config, repo: DEFAULT_REPO, assetName: "" })
            setRemote(null)
            append(`方案仓库恢复为 ${DEFAULT_REPO}`)
          }}
          disabled={busy || config.repo === DEFAULT_REPO}
        />
        <KvRow label="资产" value={config.assetName || "自动选择（优先增量包）"} />
        {remote && remote.assets.length > 1
          ? remote.assets.map((asset) => (
              <HStack key={asset.name}>
                <Text font="caption">{asset.name}</Text>
                <Spacer />
                <Button
                  title={config.assetName === asset.name ? "已选" : "选用"}
                  action={() => selectAsset(asset)}
                  disabled={busy || config.assetName === asset.name}
                />
              </HStack>
            ))
          : <Text font="caption" foregroundStyle="secondaryLabel">
              先在主页「检查更新」，这里会列出可选的资产。
            </Text>}
      </Section>

      <Section header={<Text>换方案</Text>}>
        <Text font="caption" foregroundStyle="secondaryLabel">
          先备份个人数据，再清理旧方案运行文件，安装后把个人数据补回去，最后部署。
        </Text>
        <Button
          title="从本地 zip 换方案"
          action={switchFromLocalZip}
          disabled={busy || !activeDir}
        />
        <Button
          title="从当前仓库换方案"
          action={switchFromRelease}
          disabled={busy || !activeDir}
        />
      </Section>

      <Section header={<Text>备份与回滚</Text>}>
        <KvRow
          label="当前目录"
          value={activeDir ? `${backups.length} 份快照` : "未选择"}
        />
        {backups.length === 0 ? (
          <Text font="caption" foregroundStyle="secondaryLabel">
            还没有快照。更新或从本地 zip 安装后会自动生成。
          </Text>
        ) : null}
        {backups.map((entry) => (
          <VStack key={entry.name} spacing={2}>
            <Text>{entry.name}</Text>
            <Text font="caption" foregroundStyle="secondaryLabel">
              {`${entry.version ? `v${entry.version} · ` : ""}${entry.files} 个文件`}
            </Text>
            <HStack spacing={8}>
              <Button title="回滚" action={() => rollback(entry)} disabled={busy} />
              <Button title="删除" action={() => deleteBackup(entry)} disabled={busy} />
            </HStack>
          </VStack>
        ))}
        <Button
          title="刷新备份列表"
          action={() => refreshBackups()}
          disabled={busy || !activeDir}
        />
      </Section>

      <Section header={<Text>更新设置</Text>}>
        <Toggle
          title="启动时自动检查"
          value={config.autoCheckOnLaunch}
          onChanged={(value: boolean) =>
            updateConfig({ ...config, autoCheckOnLaunch: value })
          }
        />
        <Toggle
          title="显示详细日志"
          value={config.verboseLog}
          onChanged={(value: boolean) =>
            updateConfig({ ...config, verboseLog: value })
          }
        />
        <Button title="清空日志" action={() => setLog("")} />
      </Section>

      <Section header={<Text>GitHub</Text>}>
        <KvRow label="Token" value={config.token ? "已设置" : "未设置"} />
        <Button title="设置 Token" action={editToken} />
        <Button
          title="清除 Token"
          action={() => updateConfig({ ...config, token: "" })}
          disabled={!config.token}
        />
      </Section>

      <Section header={<Text>关于</Text>}>
        <KvRow label="脚本版本" value="1.1.0" />
        <KvRow label="方案仓库" value={config.repo} />
        <KvRow label="快照目录" value={BACKUP_DIR} />
      </Section>
    </List>
  )

  const filesList = (
    <List
      navigationTitle="文件"
      navigationBarTitleDisplayMode="inline"
      listStyle="insetGroup"
    >
      <Section header={<Text>当前目录</Text>}>
        <Text>{activeDir?.path ?? "未选择目录"}</Text>
        <Button title="刷新目录" action={refreshFiles} />
      </Section>
      <Section header={<Text>目录内容</Text>}>
        {files.length === 0 ? (
          <Text foregroundStyle="secondaryLabel">目录为空或未选择目录</Text>
        ) : (
          files.map((name) => <Text key={name}>{name}</Text>)
        )}
      </Section>
    </List>
  )

  return (
    <TabView>
      <VStack
        tabItem={
          <>
            <Image systemName="house.fill" />
            <Text>主页</Text>
          </>
        }
        tag={1}
        frame={{ maxWidth: "infinity", maxHeight: "infinity" }}
      >
        <NavigationStack>{homeList}</NavigationStack>
      </VStack>
      <VStack
        tabItem={
          <>
            <Image systemName="folder.fill" />
            <Text>文件</Text>
          </>
        }
        tag={2}
        frame={{ maxWidth: "infinity", maxHeight: "infinity" }}
      >
        <NavigationStack>{filesList}</NavigationStack>
      </VStack>
      <VStack
        tabItem={
          <>
            <Image systemName="gearshape.fill" />
            <Text>设置</Text>
          </>
        }
        tag={3}
        frame={{ maxWidth: "infinity", maxHeight: "infinity" }}
      >
        <NavigationStack>{settingsList}</NavigationStack>
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
