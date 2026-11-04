// 云同步：按前端共用同步库 CheeseTigerSync/<kind>/files/<相对路径> + manifest.json。
import { Path } from "scripting"
import { exists, isDirectory, list } from "./fs"
import { collectUserData } from "./switch_scheme"
import {
  deleteFile,
  ensureRemoteDir,
  getText,
  getToFile,
  putFile,
  putText,
  type WebDavClient,
} from "./webdav"

export const SYNC_ROOT = "CheeseTigerSync"

export type SyncDevice = { id: string; name: string; at: string }
export type SyncFile = { path: string; by: string; by_name: string; at: string }
export type SyncLibrary = { devices: SyncDevice[]; files: SyncFile[] }

export function syncKey(method: string): string {
  return method === "hamster3" ? "hamster3" : method === "hamster" ? "hamster" : "manual"
}

function libraryPath(kind: string): string {
  return `${SYNC_ROOT}/${kind}/manifest.json`
}

function filePath(kind: string, rel: string): string {
  return `${SYNC_ROOT}/${kind}/files/${rel}`
}

export function isUnsafePath(rel: string): boolean {
  return (
    !rel ||
    rel.startsWith("/") ||
    rel.split("/").some((part) => part === "..")
  )
}

export async function fetchLibrary(
  client: WebDavClient,
  kind: string,
): Promise<SyncLibrary> {
  const text = await getText(client, libraryPath(kind))
  if (!text || !text.trim()) return { devices: [], files: [] }
  try {
    const data = JSON.parse(text)
    const devices: SyncDevice[] = Array.isArray(data?.devices)
      ? data.devices
          .filter((item: any) => item && item.id)
          .map((item: any) => ({
            id: String(item.id),
            name: String(item.name ?? ""),
            at: String(item.at ?? ""),
          }))
      : []
    const files: SyncFile[] = Array.isArray(data?.files)
      ? data.files
          .filter((item: any) => item && item.path && item.at)
          .map((item: any) => ({
            path: String(item.path),
            by: String(item.by ?? ""),
            by_name: String(item.by_name ?? ""),
            at: String(item.at),
          }))
      : []
    files.sort((a, b) => a.path.localeCompare(b.path))
    return { devices, files }
  } catch {
    return { devices: [], files: [] }
  }
}

async function writeLibrary(
  client: WebDavClient,
  kind: string,
  library: SyncLibrary,
) {
  await putText(client, libraryPath(kind), JSON.stringify(library, null, 2))
}

function nowIso(): string {
  return new Date().toISOString()
}

async function expandFiles(target: string, rels: string[]): Promise<string[]> {
  const result: string[] = []
  const walk = async (rel: string) => {
    const full = Path.join(target, rel)
    if (!(await exists(full))) return
    if (await isDirectory(full)) {
      for (const name of await list(full)) {
        if (!name || name === ".DS_Store") continue
        await walk(`${rel}/${name}`)
      }
      return
    }
    result.push(rel)
  }
  for (const rel of rels) await walk(rel)
  return result
}

export type PushResult = { uploaded: number; total: number }

/// 上传本机个人数据到共用同步库；同名文件覆盖。
export async function pushFiles(options: {
  client: WebDavClient
  kind: string
  target: string
  deviceId: string
  deviceName: string
  log: (line: string) => void
  files?: string[]
}): Promise<PushResult> {
  const { client, kind, target, deviceId, deviceName, log } = options
  const rels = (options.files ?? (await collectUserData(target))).filter(
    (rel) => !isUnsafePath(rel),
  )
  const files = await expandFiles(target, rels)
  if (!files.length) throw new Error("没有找到可同步的文件")

  await ensureRemoteDir(client, `${SYNC_ROOT}/${kind}/files`)
  const dirs = new Set<string>()
  const uploaded: string[] = []
  for (const rel of files) {
    const src = Path.join(target, rel)
    if (!(await exists(src))) {
      log(`  跳过不存在的 ${rel}`)
      continue
    }
    const parent = rel.split("/").slice(0, -1).join("/")
    if (parent && !dirs.has(parent)) {
      await ensureRemoteDir(client, `${SYNC_ROOT}/${kind}/files/${parent}`)
      dirs.add(parent)
    }
    await putFile(client, filePath(kind, rel), src)
    uploaded.push(rel)
    log(`  已上传 ${rel}`)
  }
  if (!uploaded.length) throw new Error("没有可上传的文件")

  const library = await fetchLibrary(client, kind)
  const now = nowIso()
  const entries = new Map<string, SyncFile>()
  for (const file of library.files) entries.set(file.path, file)
  for (const rel of uploaded) {
    entries.set(rel, { path: rel, by: deviceId, by_name: deviceName, at: now })
  }
  const devices = library.devices.filter((device) => device.id !== deviceId)
  devices.push({ id: deviceId, name: deviceName, at: now })
  await writeLibrary(client, kind, {
    devices,
    files: Array.from(entries.values()).sort((a, b) => a.path.localeCompare(b.path)),
  })
  log(`  同步库已更新（${entries.size} 个文件）`)
  return { uploaded: uploaded.length, total: entries.size }
}

/// 下载同步库全部文件到本机；覆盖前先备份个人数据。
export async function pullLibrary(options: {
  client: WebDavClient
  kind: string
  target: string
  log: (line: string) => void
  backupLabel: string
  backup: (label: string) => Promise<unknown>
}): Promise<number> {
  const { client, kind, target, log, backupLabel, backup } = options
  const library = await fetchLibrary(client, kind)
  if (!library.files.length) {
    log("  云端同步库还是空的")
    return 0
  }
  log(`  云端 ${library.files.length} 个文件`)
  await backup(backupLabel)

  let done = 0
  for (const file of library.files) {
    const rel = file.path
    if (isUnsafePath(rel)) continue
    const dest = Path.join(target, rel)
    const parent = Path.dirname(dest)
    const fm: any = (globalThis as any).FileManager
    if (typeof fm?.createDirectory === "function") {
      await fm.createDirectory(parent, true)
    }
    const ok = await getToFile(client, filePath(kind, rel), dest)
    if (ok) {
      done += 1
      log(`  已下载 ${rel}`)
    } else {
      log(`  云端缺少 ${rel}，已跳过`)
    }
  }
  log(`  已同步 ${done} 个文件到本机`)
  return done
}

export async function deleteCloudFiles(options: {
  client: WebDavClient
  kind: string
  paths: string[]
  log: (line: string) => void
}): Promise<number> {
  const { client, kind, paths, log } = options
  const targets = new Set(paths.filter((rel) => !isUnsafePath(rel)))
  let removed = 0
  for (const rel of targets) {
    const ok = await deleteFile(client, filePath(kind, rel))
    if (ok) {
      removed += 1
      log(`  已从云端删除 ${rel}`)
    } else {
      log(`  云端本来就没有 ${rel}`)
    }
  }
  const library = await fetchLibrary(client, kind)
  await writeLibrary(client, kind, {
    devices: library.devices,
    files: library.files.filter((file) => !targets.has(file.path)),
  })
  return removed
}
