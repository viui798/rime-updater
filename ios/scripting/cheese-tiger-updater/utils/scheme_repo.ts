// 本地方案仓库：下载缓存目录里的 zip（下载 + 导入），支持勾选一个优先更新。
import { Path } from "scripting"
import { FM, getFileSize } from "./common"
import { copy, ensureDir, exists, isDirectory, list } from "./fs"
import { downloadCacheDir, inferVersionFromName } from "./install"

export type SchemeEntry = {
  name: string
  path: string
  version: string
  size: number
  imported: boolean
}

function schemeDir(): string {
  return downloadCacheDir()
}

/// 列出仓库里的 zip（按名称排序），importedNames 用来标注来源。
export async function listSchemes(importedNames: string[]): Promise<SchemeEntry[]> {
  const dir = schemeDir()
  if (!(await exists(dir))) return []
  const imported = new Set((importedNames ?? []).filter(Boolean))
  const entries: SchemeEntry[] = []
  for (const name of await list(dir)) {
    if (!name || name === ".DS_Store" || !name.toLowerCase().endsWith(".zip")) continue
    const path = Path.join(dir, name)
    if (await isDirectory(path)) continue
    let size = 0
    try {
      size = await getFileSize(FM(), path)
    } catch {}
    entries.push({
      name,
      path,
      version: inferVersionFromName(name),
      size,
      imported: imported.has(name),
    })
  }
  entries.sort((a, b) => a.name.toLowerCase().localeCompare(b.name.toLowerCase()))
  return entries
}

/// 把外部 zip 复制进仓库；同名自动加序号，返回新文件名。
export async function importScheme(sourcePath: string): Promise<string> {
  const dir = schemeDir()
  await ensureDir(dir)
  const base = String(sourcePath ?? "").split("/").pop() || "local.zip"
  const dot = base.lastIndexOf(".")
  const stem = dot > 0 ? base.slice(0, dot) : base
  const ext = dot > 0 ? base.slice(dot) : ".zip"
  let name = base
  let counter = 2
  while (await exists(Path.join(dir, name))) {
    name = `${stem}-${counter}${ext}`
    counter += 1
  }
  await copy(sourcePath, Path.join(dir, name))
  return name
}

/// 删除仓库里的一个包；只删文件，不动设备。
export async function removeScheme(name: string): Promise<void> {
  const path = Path.join(schemeDir(), name)
  if (!(await exists(path))) return
  try {
    await FM().remove(path)
  } catch {
    // 占用中时由调用方提示失败
  }
}

/// 勾选的方案文件路径；文件不存在时返回 null。
export async function selectedSchemePath(name: string): Promise<string | null> {
  const value = String(name ?? "").trim()
  if (!value) return null
  const path = Path.join(schemeDir(), value)
  return (await exists(path)) ? path : null
}
