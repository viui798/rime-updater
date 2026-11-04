import { Path } from "scripting"
import {
  FM,
  compilePatterns,
  getFileSize,
  matchAny,
  normalizePath,
  removePathLoose,
  tempDownloadPath,
} from "./common"
import { downloadWithProgress, type DownloadProgress } from "./downloader"
import {
  copy,
  ensureDir,
  exists,
  isDirectory,
  list,
  removeDirSafe,
} from "./fs"
import type { ReleaseAsset } from "./github"

const MAX_BACKUP_BYTES = 32 * 1024 * 1024
const BACKUP_DIR = ".cheese-tiger-backup"
const MANIFEST_NAME = "manifest.json"

type SnapshotManifest = {
  created: string
  version: string
  added: string[]
  overwritten: string[]
}

async function writeManifest(backupRoot: string, manifest: SnapshotManifest) {
  try {
    const fm = FM()
    if (typeof fm?.writeAsString === "function") {
      await ensureDir(backupRoot)
      await fm.writeAsString(
        Path.join(backupRoot, MANIFEST_NAME),
        JSON.stringify(manifest, null, 2),
      )
    }
  } catch {}
}

async function readManifest(backupPath: string): Promise<SnapshotManifest | null> {
  try {
    const fm = FM()
    if (typeof fm?.readAsString !== "function") return null
    const raw = await fm.readAsString(Path.join(backupPath, MANIFEST_NAME))
    if (!raw) return null
    const parsed = JSON.parse(String(raw))
    if (!parsed || typeof parsed !== "object") return null
    return {
      created: String(parsed.created ?? ""),
      version: String(parsed.version ?? ""),
      added: Array.isArray(parsed.added) ? parsed.added.map(String) : [],
      overwritten: Array.isArray(parsed.overwritten)
        ? parsed.overwritten.map(String)
        : [],
    }
  } catch {
    return null
  }
}

// 与桌面端 applyZip 的白名单一致：方案文件更新，个人数据不动。
const EXCLUDES = [
  "DELTA.json",
  "user.yaml",
  "installation.yaml",
  "reverse_freq.txt",
  "custom_phrase.txt",
  "*.userdb",
  "*.options.yaml",
  "*.log",
  "*.md",
  "build",
  "sync",
  ".cheese-tiger-backup",
  "*.zip",
  "*.sha256",
]

const patterns = compilePatterns(EXCLUDES)

function excluded(name: string, rel: string): boolean {
  return matchAny(name, patterns) || matchAny(rel, patterns)
}

function stamp(): string {
  const now = new Date()
  const two = (value: number) => String(value).padStart(2, "0")
  return (
    `${now.getFullYear()}${two(now.getMonth() + 1)}${two(now.getDate())}` +
    `-${two(now.getHours())}${two(now.getMinutes())}${two(now.getSeconds())}`
  )
}

export function inferVersionFromName(name: string): string {
  const hit = String(name ?? "").match(/v?(\d+\.\d+\.\d+(?:\.\d+)?)/i)
  return hit ? hit[1] : ""
}

export async function downloadAsset(
  asset: ReleaseAsset,
  log: (line: string) => void,
  onProgress?: (progress: DownloadProgress) => void,
): Promise<string> {
  const dest = tempDownloadPath(asset.name)
  await removePathLoose(dest)
  log(`下载 ${asset.name}…`)
  await downloadWithProgress(asset.url, dest, onProgress)
  return dest
}

/// 增量包是 update/ 前缀；完整包可能是一个顶层目录或扁平结构。
async function resolveSource(tmp: string): Promise<string> {
  const update = Path.join(tmp, "update")
  if ((await exists(update)) && (await isDirectory(update))) return update

  const children = (await list(tmp)).filter(
    (name) => name !== "__MACOSX" && name !== ".DS_Store",
  )
  if (children.length === 1) {
    const only = Path.join(tmp, children[0])
    if (await isDirectory(only)) return only
  }
  return tmp
}

async function withUnzipped<T>(
  zipPath: string,
  fn: (source: string) => Promise<T>,
): Promise<T> {
  const fm = FM()
  const tmp = Path.join(
    fm.temporaryDirectory ?? Path.dirname(zipPath),
    `cheese_tiger_unzip_${Date.now()}`,
  )
  await removeDirSafe(tmp)
  await ensureDir(tmp)
  try {
    await fm.unzip(zipPath, tmp)
    const source = await resolveSource(tmp)
    return await fn(source)
  } finally {
    await removeDirSafe(tmp)
  }
}

async function walkFiles(
  root: string,
  current: string,
  visit: (rel: string, src: string) => Promise<void>,
  onSkip?: () => void,
) {
  for (const name of await list(current)) {
    if (!name || name === "__MACOSX" || name === ".DS_Store") continue
    const src = Path.join(current, name)
    const rel = src.slice(root.length + 1)
    if (excluded(name, rel)) {
      onSkip?.()
      continue
    }
    if (await isDirectory(src)) {
      await walkFiles(root, src, visit, onSkip)
      continue
    }
    await visit(rel, src)
  }
}

export type PlanResult = {
  updated: number
  added: number
  skipped: number
  files: string[]
}

/// 仅预演：解压后逐个比对，不写盘、不备份。
export async function planZip(
  zipPath: string,
  target: string,
): Promise<PlanResult> {
  const dir = normalizePath(target)
  let updated = 0
  let added = 0
  let skipped = 0
  const files: string[] = []

  await withUnzipped(zipPath, async (source) => {
    await walkFiles(
      source,
      source,
      async (rel) => {
        if (await exists(Path.join(dir, rel))) {
          updated += 1
          files.push(`更新 ${rel}`)
        } else {
          added += 1
          files.push(`新增 ${rel}`)
        }
      },
      () => {
        skipped += 1
      },
    )
  })

  return { updated, added, skipped, files }
}

async function backupTree(
  root: string,
  current: string,
  target: string,
  backupRoot: string,
  log: (line: string) => void,
) {
  for (const name of await list(current)) {
    if (!name || name === "__MACOSX" || name === ".DS_Store") continue
    const src = Path.join(current, name)
    const rel = src.slice(root.length + 1)
    if (excluded(name, rel)) continue

    if (await isDirectory(src)) {
      await backupTree(root, src, target, backupRoot, log)
      continue
    }

    const dst = Path.join(target, rel)
    if (!(await exists(dst))) continue
    const size = await getFileSize(FM(), dst)
    if (size > MAX_BACKUP_BYTES) {
      log(`  ! ${rel} 体积较大，未备份`)
      continue
    }
    const backup = Path.join(backupRoot, rel)
    await ensureDir(Path.dirname(backup))
    await copy(dst, backup)
  }
}

async function copyTree(
  root: string,
  current: string,
  target: string,
  log: (line: string) => void,
  counter: { copied: number },
) {
  for (const name of await list(current)) {
    if (!name || name === ".DS_Store") continue
    if (root === current && name === MANIFEST_NAME) continue
    const src = Path.join(current, name)
    const rel = src.slice(root.length + 1)
    const dst = Path.join(target, rel)
    if (await isDirectory(src)) {
      await copyTree(root, src, target, log, counter)
      continue
    }
    await ensureDir(Path.dirname(dst))
    if (await exists(dst)) {
      try { await FM().remove(dst) } catch {}
    }
    await copy(src, dst)
    counter.copied += 1
    log(`  恢复 ${rel}`)
  }
}

export type InstallResult = {
  copied: number
  skipped: number
  backupRoot: string
  version: string
}

export async function installZip(
  zipPath: string,
  target: string,
  version: string,
  log: (line: string) => void,
): Promise<InstallResult> {
  const dir = normalizePath(target)
  const backupRoot = Path.join(dir, BACKUP_DIR, stamp())
  const manifest: SnapshotManifest = {
    created: stamp(),
    version,
    added: [],
    overwritten: [],
  }
  let copied = 0
  let skipped = 0

  await withUnzipped(zipPath, async (source) => {
    await backupTree(source, source, dir, backupRoot, log)
    await walkFiles(source, source, async (rel, src) => {
      const dst = Path.join(dir, rel)
      await ensureDir(Path.dirname(dst))
      if (await exists(dst)) {
        manifest.overwritten.push(rel)
        try { await FM().remove(dst) } catch {}
      } else {
        manifest.added.push(rel)
      }
      await copy(src, dst)
      copied += 1
      log(`  更新 ${rel}`)
    })
    await writeManifest(backupRoot, manifest)
  })

  return { copied, skipped, backupRoot, version }
}

/// 把选中的本地 zip 拷到临时目录，避免 iCloud 未下载的路径无法直接解压。
export async function stageLocalZip(pickedPath: string): Promise<string> {
  const name = Path.basename(pickedPath) || "local.zip"
  const dest = tempDownloadPath(name)
  await removePathLoose(dest)
  await copy(pickedPath, dest)
  return dest
}

export type BackupEntry = {
  name: string
  path: string
  files: number
  version?: string
}

/// 列出某目录下的全部快照（新 -> 旧）。
export async function listBackups(target: string): Promise<BackupEntry[]> {
  const root = Path.join(normalizePath(target), BACKUP_DIR)
  if (!(await exists(root))) return []
  const entries: BackupEntry[] = []
  for (const name of await list(root)) {
    if (!name || name.startsWith(".") || name.startsWith("switch-")) continue
    const path = Path.join(root, name)
    if (!(await isDirectory(path))) continue
    let files = 0
    await walkAll(path, async () => {
      files += 1
    })
    const manifest = await readManifest(path)
    if (await exists(Path.join(path, MANIFEST_NAME))) files = Math.max(0, files - 1)
    entries.push({ name, path, files, version: manifest?.version ?? "" })
  }
  entries.sort((a, b) => b.name.localeCompare(a.name))
  return entries
}

async function walkAll(current: string, visit: () => Promise<void>) {
  for (const name of await list(current)) {
    if (!name || name === ".DS_Store") continue
    const full = Path.join(current, name)
    if (await isDirectory(full)) {
      await walkAll(full, visit)
      continue
    }
    await visit()
  }
}

export async function restoreBackup(
  target: string,
  backupPath: string,
  log: (line: string) => void,
): Promise<number> {
  const dir = normalizePath(target)
  const manifest = await readManifest(backupPath)
  if (manifest) {
    for (const rel of manifest.added) {
      const path = Path.join(dir, rel)
      if (await exists(path)) {
        await removePathLoose(path)
        log(`  删除 ${rel}`)
      }
    }
  }
  const counter = { copied: 0 }
  await copyTree(backupPath, backupPath, dir, log, counter)
  return counter.copied
}

export async function removeBackup(backupPath: string) {
  await removeDirSafe(backupPath)
}

export { BACKUP_DIR }
