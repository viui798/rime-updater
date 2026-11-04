import { Path } from "scripting"
import {
  copy,
  ensureDir,
  exists,
  isDirectory,
  list,
  remove,
} from "./fs"
import { installZip } from "./install"

const USER_DATA_FILES = [
  "user.yaml",
  "installation.yaml",
  "reverse_freq.txt",
  "custom_phrase.txt",
]

const RUNTIME_DIRS = ["lua", "opencc", "models", "dicts", "tiger_dicts", "zuci", "build"]

const LUA_STATS = [
  "lua/kc_count.txt",
  "lua/kc_total.txt",
  "lua/kc_last.txt",
  "lua/quote.txt",
]

function stamp(): string {
  const now = new Date()
  const two = (value: number) => String(value).padStart(2, "0")
  return (
    `${now.getFullYear()}${two(now.getMonth() + 1)}${two(now.getDate())}` +
    `-${two(now.getHours())}${two(now.getMinutes())}${two(now.getSeconds())}`
  )
}

function isUserDataFile(name: string): boolean {
  return (
    name.endsWith(".custom.yaml") ||
    name.endsWith(".options.yaml") ||
    USER_DATA_FILES.includes(name)
  )
}

async function existsInDir(dir: string, name: string): Promise<boolean> {
  return exists(Path.join(dir, name))
}

/// 收集需要保留的个人数据（相对路径，可能是文件或 *.userdb 目录）。
export async function collectUserData(target: string): Promise<string[]> {
  if (!(await exists(target))) return []
  const result: string[] = []

  for (const name of await list(target)) {
    if (!name || name === "." || name === "..") continue
    const full = Path.join(target, name)
    const dir = await isDirectory(full)
    if (!dir && (isUserDataFile(name) || (name.startsWith("自学习-") && name.endsWith(".txt")))) {
      result.push(name)
    } else if (dir && name.endsWith(".userdb")) {
      result.push(name)
    }
  }

  for (const rel of LUA_STATS) {
    if (await existsInDir(target, rel)) result.push(rel)
  }

  const lua = Path.join(target, "lua")
  if (await exists(lua)) {
    for (const name of await list(lua)) {
      const full = Path.join(lua, name)
      const dir = await isDirectory(full)
      if (!dir && name.startsWith("input_stats_") && name.endsWith(".lua")) {
        result.push(`lua/${name}`)
      } else if (dir && name.endsWith(".userdb")) {
        result.push(`lua/${name}`)
      }
    }
  }
  return result
}

async function copyRecursive(src: string, dst: string) {
  await ensureDir(dst)
  for (const name of await list(src)) {
    if (!name || name === ".DS_Store") continue
    const from = Path.join(src, name)
    const to = Path.join(dst, name)
    if (await isDirectory(from)) {
      await copyRecursive(from, to)
      continue
    }
    await ensureDir(Path.dirname(to))
    if (await exists(to)) {
      try { await remove(to) } catch {}
    }
    await copy(from, to)
  }
}

export type SwitchBackup = {
  directory: string
  files: string[]
  target: string
}

/// 把个人数据复制到 <Rime>/.cheese-tiger-backup/switch-<时间戳>/<标签>/。
export async function backupUserData(
  target: string,
  label: string,
  log: (line: string) => void,
): Promise<SwitchBackup> {
  const safeLabel = label.replace(/[^\w\u4e00-\u9fa5-]/g, "_") || "scheme"
  const directory = Path.join(target, ".cheese-tiger-backup", `switch-${stamp()}`, safeLabel)
  await ensureDir(directory)

  const files = await collectUserData(target)
  for (const rel of files) {
    const src = Path.join(target, rel)
    const dst = Path.join(directory, rel)
    if (await isDirectory(src)) {
      await copyRecursive(src, dst)
    } else if (await exists(src)) {
      await ensureDir(Path.dirname(dst))
      await copy(src, dst)
    }
    log(`  备份 ${rel}`)
  }
  log(`  个人数据已备份到 ${directory}`)
  return { directory, files, target }
}

/// 删除旧方案的运行文件，保留个人数据与备份目录。
export async function cleanScheme(
  target: string,
  log: (line: string) => void,
) {
  for (const name of RUNTIME_DIRS) {
    const dir = Path.join(target, name)
    if (!(await exists(dir))) continue
    try {
      await remove(dir)
      log(`  清理 ${name}/`)
    } catch {
      log(`  ! 无法清理 ${name}/`)
    }
  }

  for (const name of await list(target)) {
    if (!name.endsWith(".yaml")) continue
    if (isUserDataFile(name)) continue
    const full = Path.join(target, name)
    if (await isDirectory(full)) continue
    try {
      await remove(full)
      log(`  删除旧方案配置 ${name}`)
    } catch {}
  }
}

/// 新方案装完后，把备份里缺失的个人数据补回去（主要是 lua 统计文件）。
export async function restoreUserData(
  backup: SwitchBackup,
  log: (line: string) => void,
) {
  for (const rel of backup.files) {
    const src = Path.join(backup.directory, rel)
    const dst = Path.join(backup.target, rel)
    if (await exists(dst)) continue
    if (await isDirectory(src)) {
      await copyRecursive(src, dst)
    } else if (await exists(src)) {
      await ensureDir(Path.dirname(dst))
      await copy(src, dst)
    }
    log(`  恢复个人数据 ${rel}`)
  }
}

export type SwitchResult = {
  copied: number
  backupRoot: string
  snapshotRoot: string
}

export async function switchScheme(
  zipPath: string,
  target: string,
  label: string,
  version: string,
  log: (line: string) => void,
): Promise<SwitchResult> {
  log("换方案：备份个人数据")
  const backup = await backupUserData(target, label, log)
  log("换方案：清理旧运行文件")
  await cleanScheme(target, log)
  log("换方案：安装新方案")
  const result = await installZip(zipPath, target, version, log)
  log("换方案：恢复个人数据")
  await restoreUserData(backup, log)
  return {
    copied: result.copied,
    backupRoot: backup.directory,
    snapshotRoot: result.backupRoot,
  }
}
