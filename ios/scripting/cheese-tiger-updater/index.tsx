import {
  Button,
  List,
  Navigation,
  NavigationStack,
  Section,
  Text,
  useState,
} from "scripting"

import { storage } from "./utils/common"
import { deployInputMethod, type InputMethod } from "./utils/deploy"
import { fetchLatest, type ReleaseInfo } from "./utils/github"
import { downloadAsset, installZip } from "./utils/install"

console.log("[cheese-tiger] script loaded")

const CONFIG_KEY = "cheese_tiger_ios_config"

type Config = {
  bookmarkName: string
  path: string
  inputMethod: InputMethod
  token: string
  installedVersion: string
}

function loadConfig(): Config {
  try {
    const raw = storage()?.get?.(CONFIG_KEY)
    if (typeof raw === "string" && raw.trim()) {
      const data = JSON.parse(raw)
      return {
        bookmarkName: String(data.bookmarkName ?? ""),
        path: String(data.path ?? ""),
        inputMethod:
          data.inputMethod === "hamster3"
            ? "hamster3"
            : data.inputMethod === "none"
              ? "none"
              : "hamster",
        token: String(data.token ?? ""),
        installedVersion: String(data.installedVersion ?? ""),
      }
    }
  } catch {}
  return {
    bookmarkName: "",
    path: "",
    inputMethod: "hamster",
    token: "",
    installedVersion: "",
  }
}

function saveConfig(config: Config) {
  try {
    storage()?.set?.(CONFIG_KEY, JSON.stringify(config))
  } catch {}
}

function UpdaterView() {
  const [config, setConfig] = useState<Config>(loadConfig())
  const [remote, setRemote] = useState<ReleaseInfo | null>(null)
  const [busy, setBusy] = useState(false)
  const [percent, setPercent] = useState(0)
  const [log, setLog] = useState("")

  function append(line: string) {
    setLog((previous) => (previous ? `${previous}\n${line}` : line))
  }

  function updateConfig(next: Config) {
    setConfig(next)
    saveConfig(next)
  }

  async function resolveTarget(): Promise<string> {
    const fm: any = (globalThis as any).FileManager
    const name = config.bookmarkName.trim()
    if (name && typeof fm?.bookmarkedPath === "function") {
      try {
        const resolved = await fm.bookmarkedPath(name)
        if (resolved) return String(resolved)
      } catch {}
    }
    return config.path.trim()
  }

  async function pickFolder() {
    const picker: any = (globalThis as any).DocumentPicker
    if (typeof picker?.pickDirectoryBookmark !== "function") {
      append("当前 Scripting 版本不支持直接选择目录，请先升级 Scripting。")
      return
    }
    try {
      const result = await picker.pickDirectoryBookmark({
        initialDirectory: config.path || undefined,
      })
      if (!result) return
      const next: Config = {
        ...config,
        bookmarkName: String(result.bookmarkName ?? ""),
        path: String(result.path ?? ""),
      }
      updateConfig(next)
      append(`已选择目录：${next.path}`)
    } catch (error: any) {
      append(`✗ 选择目录失败：${String(error?.message ?? error)}`)
    }
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

  async function install() {
    if (busy) return
    const target = await resolveTarget()
    if (!target) {
      append("请先在「文件」App 里选择仓 / 元书的 Rime 目录。")
      return
    }

    setBusy(true)
    setPercent(0)
    try {
      const release = remote ?? (await fetchLatest(config.token))
      if (!remote) setRemote(release)
      append(`准备安装 v${release.version} 到 ${target}`)
      const zip = await downloadAsset(release.chosen, append, (progress) => {
        if (typeof progress.percent === "number") {
          setPercent(Math.max(0, Math.min(1, progress.percent)))
        }
      })
      const result = await installZip(zip, target, release.version, append)
      append(`完成：更新 ${result.copied} 个文件，跳过 ${result.skipped} 个`)
      append(`备份：${result.backupRoot}`)
      updateConfig({ ...config, installedVersion: release.version })

      if (config.inputMethod === "none") {
        append("请到输入法里手动重新部署")
      } else {
        append("正在请求输入法重新部署…")
        await deployInputMethod(config.inputMethod)
        append("已请求部署")
      }
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
          <Text>{config.path || "未选择目录"}</Text>
          <Text foregroundStyle="secondaryLabel">
            在「文件」App 里选 我的 iPhone/Hamster/Rime 或元书的用户目录。
          </Text>
          <Button title="选择目录" action={pickFolder} />
        </Section>

        <Section header={<Text>远端</Text>}>
          <Text>
            {remote
              ? `v${remote.version} · ${remote.chosen.name}`
              : "未检查"}
          </Text>
          <Text foregroundStyle="secondaryLabel">
            {`上次安装：${config.installedVersion || "无"}`}
          </Text>
          <Button
            title="检查更新"
            action={check}
            disabled={busy}
          />
        </Section>

        <Section header={<Text>安装</Text>}>
          <Button
            title={remote ? `下载并安装 v${remote.version}` : "下载并安装"}
            action={install}
            disabled={busy}
          />
          {busy && percent > 0 ? (
            <Text foregroundStyle="secondaryLabel">
              {`下载 ${Math.round(percent * 100)}%`}
            </Text>
          ) : null}
        </Section>

        <Section header={<Text>部署方式</Text>}>
          <Text>
            {`当前：${
              config.inputMethod === "hamster"
                ? "仓输入法"
                : config.inputMethod === "hamster3"
                  ? "元书"
                  : "手动部署"
            }`}
          </Text>
          <Button
            title="用仓输入法部署"
            action={() =>
              updateConfig({ ...config, inputMethod: "hamster" })
            }
          />
          <Button
            title="用元书部署"
            action={() =>
              updateConfig({ ...config, inputMethod: "hamster3" })
            }
          />
          <Button
            title="手动部署"
            action={() => updateConfig({ ...config, inputMethod: "none" })}
          />
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
