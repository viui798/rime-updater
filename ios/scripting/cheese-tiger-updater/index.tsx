import {
  Button,
  HStack,
  List,
  Navigation,
  NavigationStack,
  Section,
  Text,
  VStack,
  useState,
} from "scripting"

import { basename, storage } from "./utils/common"
import { deployInputMethod, type InputMethod } from "./utils/deploy"
import { fetchLatest, type ReleaseInfo } from "./utils/github"
import { downloadAsset, installZip } from "./utils/install"

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

  // 兼容单目录版本
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
  }
}

function loadConfig(): Config {
  try {
    const raw = storage()?.get?.(CONFIG_KEY)
    if (typeof raw === "string" && raw.trim()) {
      return normalizeConfig(JSON.parse(raw))
    }
  } catch {}
  return { dirs: [], activeId: "", token: "", installedVersions: {} }
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

function UpdaterView() {
  const [config, setConfig] = useState<Config>(loadConfig())
  const [remote, setRemote] = useState<ReleaseInfo | null>(null)
  const [busy, setBusy] = useState(false)
  const [percent, setPercent] = useState(0)
  const [log, setLog] = useState("")

  const activeDir =
    config.dirs.find((dir) => dir.id === config.activeId) ?? config.dirs[0]

  function append(line: string) {
    setLog((previous) => (previous ? `${previous}\n${line}` : line))
  }

  function updateConfig(next: Config) {
    setConfig(next)
    saveConfig(next)
  }

  function setActive(id: string) {
    updateConfig({ ...config, activeId: id })
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

  async function pickFolder() {
    const picker: any = (globalThis as any).DocumentPicker
    if (typeof picker?.pickDirectoryBookmark !== "function") {
      append("当前 Scripting 版本不支持直接选择目录，请先升级 Scripting。")
      return
    }
    try {
      const result = await picker.pickDirectoryBookmark({
        initialDirectory: activeDir?.path || undefined,
      })
      if (!result) return
      const path = String(result.path ?? "").trim()
      if (!path) return
      const bookmarkName = String(result.bookmarkName ?? "")
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
      const next: Config = {
        ...config,
        dirs: [...config.dirs, dir],
        activeId: dir.id,
      }
      updateConfig(next)
      append(`已添加目录：${name}（${methodLabel(dir.inputMethod)}部署）`)
    } catch (error: any) {
      append(`✗ 选择目录失败：${String(error?.message ?? error)}`)
    }
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

  async function check() {
    if (busy) return
    setBusy(true)
    try {
      append("检查远端版本…")
      const release = await fetchLatest(config.token)
      setRemote(release)
      append(`远端最新：v${release.version}（${release.chosen.name}）`)
    } catch (error: any) {
      append(`✗ ${String(error?.message ?? error)}`)
    } finally {
      setBusy(false)
    }
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
      const release = remote ?? (await fetchLatest(config.token))
      if (!remote) setRemote(release)
      append(`准备安装 v${release.version} 到 ${targets.length} 个目录`)
      const zip = await downloadAsset(release.chosen, append, (progress) => {
        if (typeof progress.percent === "number") {
          setPercent(Math.max(0, Math.min(1, progress.percent)))
        }
      })

      const installedVersions = { ...config.installedVersions }
      for (const dir of targets) {
        const target = await resolveTarget(dir)
        if (!target) {
          append(`✗ ${dir.name}：找不到目录`)
          continue
        }
        append(`[${dir.name}] 安装到 ${target}`)
        const result = await installZip(zip, target, release.version, append)
        append(`[${dir.name}] 更新 ${result.copied} 个文件，跳过 ${result.skipped} 个`)
        append(`[${dir.name}] 备份：${result.backupRoot}`)
        installedVersions[dir.id] = release.version

        if (dir.inputMethod === "none") {
          append(`[${dir.name}] 请手动部署`)
        } else {
          append(`[${dir.name}] 请求 ${methodLabel(dir.inputMethod)} 部署…`)
          try {
            await deployInputMethod(dir.inputMethod)
            append(`[${dir.name}] 已请求部署`)
          } catch (error: any) {
            append(`[${dir.name}] ✗ 部署失败：${String(error?.message ?? error)}`)
          }
        }
      }
      updateConfig({ ...config, installedVersions })
      append("全部完成")
    } catch (error: any) {
      append(`✗ ${String(error?.message ?? error)}`)
    } finally {
      setBusy(false)
      setPercent(0)
    }
  }

  return (
    <NavigationStack>
      <List
        navigationTitle="芝士虎整更新器"
        navigationBarTitleDisplayMode="inline"
        listStyle="insetGroup"
      >
        <Section header={<Text>Rime 用户目录</Text>}>
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
                <Button
                  title="重命名"
                  action={() => renameDir(dir)}
                  disabled={busy}
                />
                <Button
                  title="部署方式"
                  action={() => cycleMethod(dir)}
                  disabled={busy}
                />
                <Button
                  title="移除"
                  action={() => removeDir(dir)}
                  disabled={busy}
                />
              </HStack>
            </VStack>
          ))}
          <Button title="添加目录" action={pickFolder} disabled={busy} />
        </Section>

        <Section header={<Text>远端</Text>}>
          <Text>
            {remote ? `v${remote.version} · ${remote.chosen.name}` : "未检查"}
          </Text>
          <Button title="检查更新" action={check} disabled={busy} />
        </Section>

        <Section header={<Text>安装</Text>}>
          <Text>
            {activeDir ? `当前目录：${activeDir.name}` : "请先添加目录"}
          </Text>
          <Button
            title={remote ? `安装 v${remote.version} 到当前目录` : "安装到当前目录"}
            action={() => install(false)}
            disabled={busy || !activeDir}
          />
          {config.dirs.length > 1 ? (
            <Button
              title={remote ? `安装 v${remote.version} 到全部目录` : "安装到全部目录"}
              action={() => install(true)}
              disabled={busy}
            />
          ) : null}
          {busy && percent > 0 ? (
            <Text foregroundStyle="secondaryLabel">
              {`下载 ${Math.round(percent * 100)}%`}
            </Text>
          ) : null}
        </Section>

        <Section header={<Text>日志</Text>}>
          <Text font="caption">{log || "等待操作"}</Text>
        </Section>
      </List>
    </NavigationStack>
  )
}

async function run() {
  try {
    await Navigation.present({
      element: <UpdaterView />,
      modalPresentationStyle: "overFullScreen",
    })
  } catch (error) {
    console.error("[cheese-tiger] 启动失败", error)
  }
}

run()
