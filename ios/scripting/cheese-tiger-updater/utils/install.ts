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
  copyDirWithPolicy,
  copy,
  ensureDir,
  exists,
  isDirectory,
  list,
  removeDirSafe,
} from "./fs"
import type { ReleaseAsset } from "./github"

const MAX_BACKUP_BYTES = 32 * 1024 * 1024

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
  const fm = FM()
  const tmp = Path.join(
    fm.temporaryDirectory ?? Path.dirname(zipPath),
    `cheese_tiger_unzip_${Date.now()}`,
  )
  const dir = normalizePath(target)
  const backupRoot = Path.join(dir, ".cheese-tiger-backup", stamp())
  let copied = 0
  let skipped = 0

  await removeDirSafe(tmp)
  await ensureDir(tmp)
  try {
    await fm.unzip(zipPath, tmp)
    const source = await resolveSource(tmp)
    await backupTree(source, source, dir, backupRoot, log)
    await copyDirWithPolicy(source, dir, {
      excludePatterns: EXCLUDES,
      overwritePolicy: "overwrite",
      onCopiedFile: (_dst, rel) => {
        copied += 1
        log(`  更新 ${rel}`)
      },
      onSkippedFile: (_src, rel) => {
        skipped += 1
      },
    })
  } finally {
    await removeDirSafe(tmp)
  }

  return { copied, skipped, backupRoot, version }
}
