import { basename, storage } from "./common"
import type { InputMethod } from "./deploy"
import { DEFAULT_REPO, parseRepo } from "./github"

export const SCRIPT_VERSION = "1.5.1"

const CONFIG_KEY = "cheese_tiger_ios_config"
const PASSWORD_KEY = "cheese_tiger_webdav_password"

export type DirEntry = {
  id: string
  name: string
  bookmarkName: string
  path: string
  inputMethod: InputMethod
}

export type Config = {
  dirs: DirEntry[]
  activeId: string
  token: string
  installedVersions: Record<string, string>
  autoCheckOnLaunch: boolean
  verboseLog: boolean
  repo: string
  assetName: string
  syncUrl: string
  syncUser: string
  deviceName: string
  deviceId: string
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
    syncUrl: String(data?.syncUrl ?? ""),
    syncUser: String(data?.syncUser ?? ""),
    deviceName: String(data?.deviceName ?? "iPhone"),
    deviceId: String(data?.deviceId ?? ""),
  }
}

export function loadConfig(): Config {
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
    syncUrl: "",
    syncUser: "",
    deviceName: "iPhone",
    deviceId: "",
  }
}

export function saveConfig(config: Config) {
  try {
    storage()?.set?.(CONFIG_KEY, JSON.stringify(config))
  } catch {}
}

export function loadPassword(): string {
  try {
    const keychain: any = (globalThis as any).Keychain
    const value = keychain?.get?.(PASSWORD_KEY)
    if (value) return String(value)
  } catch {}
  try {
    return String(storage()?.get?.(PASSWORD_KEY) ?? "")
  } catch {
    return ""
  }
}

export function persistPassword(password: string) {
  try {
    const keychain: any = (globalThis as any).Keychain
    if (typeof keychain?.set === "function") {
      keychain.set(PASSWORD_KEY, password)
      return
    }
  } catch {}
  try {
    storage()?.set?.(PASSWORD_KEY, password)
  } catch {}
}

export function methodLabel(method: InputMethod): string {
  return method === "hamster3" ? "元书" : method === "none" ? "手动" : "仓输入法"
}

export function inferMethod(path: string, name: string): InputMethod {
  const value = `${path} ${name}`.toLowerCase()
  if (value.includes("hamster3") || name.includes("元书")) return "hamster3"
  return "hamster"
}
