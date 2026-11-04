// 极简 WebDAV 客户端：MKCOL / PUT / GET / DELETE + Basic Auth。
import { fetch } from "scripting"

export type WebDavClient = {
  base: string
  username: string
  password: string
}

function normalizeBase(url: string): string {
  return String(url ?? "").trim().replace(/\/+$/, "")
}

/// 路径逐段编码，支持中文文件名。
function encodePath(path: string): string {
  return String(path ?? "")
    .split("/")
    .filter((part, index) => part || index === 0)
    .map((part) => encodeURIComponent(part))
    .join("/")
}

function base64Fallback(text: string): string {
  const chars =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  const bytes = []
  for (let i = 0; i < text.length; i++) {
    const code = text.charCodeAt(i)
    if (code < 128) {
      bytes.push(code)
    } else {
      bytes.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f))
    }
  }
  let out = ""
  for (let i = 0; i < bytes.length; i += 3) {
    const a = bytes[i]
    const b = i + 1 < bytes.length ? bytes[i + 1] : undefined
    const c = i + 2 < bytes.length ? bytes[i + 2] : undefined
    out += chars[a >> 2]
    out += chars[((a & 3) << 4) | ((b ?? 0) >> 4)]
    out += b === undefined ? "=" : chars[((b & 15) << 2) | ((c ?? 0) >> 6)]
    out += c === undefined ? "=" : chars[c & 63]
  }
  return out
}

function authHeader(client: WebDavClient): string {
  const raw = `${client.username}:${client.password}`
  try {
    const DataApi: any = (globalThis as any).Data
    if (typeof DataApi?.fromString === "function") {
      const data = DataApi.fromString(raw)
      const encoded = data?.toBase64String?.()
      if (encoded) return `Basic ${encoded}`
    }
  } catch {}
  return `Basic ${base64Fallback(raw)}`
}

export function createClient(
  url: string,
  username: string,
  password: string,
): WebDavClient {
  return {
    base: normalizeBase(url),
    username: String(username ?? "").trim(),
    password: String(password ?? ""),
  }
}

export function isClientReady(client: WebDavClient): boolean {
  return !!client.base
}

async function request(
  client: WebDavClient,
  path: string,
  init: any = {},
): Promise<any> {
  if (!client.base) throw new Error("还没有填写 WebDAV 地址")
  const headers: Record<string, string> = { ...(init.headers ?? {}) }
  headers.Authorization = authHeader(client)
  const url = `${client.base}/${encodePath(path)}`
  return await fetch(url, { ...init, headers, timeout: 30 })
}

/// 逐级创建远端目录；已存在（405）视为成功。
export async function ensureRemoteDir(client: WebDavClient, path: string) {
  const parts = String(path ?? "").split("/").filter(Boolean)
  let current = ""
  for (const part of parts) {
    current = current ? `${current}/${part}` : part
    const res = await request(client, current, { method: "MKCOL" })
    if (!res.ok && res.status !== 405) {
      throw new Error(`创建目录失败：${current}（HTTP ${res.status}）`)
    }
  }
}

export async function putText(
  client: WebDavClient,
  path: string,
  text: string,
) {
  const res = await request(client, path, {
    method: "PUT",
    headers: { "Content-Type": "application/json; charset=utf-8" },
    body: text,
  })
  if (!res.ok) throw new Error(`上传失败：${path}（HTTP ${res.status}）`)
}

export async function getText(
  client: WebDavClient,
  path: string,
): Promise<string | null> {
  const res = await request(client, path)
  if (res.status === 404) return null
  if (!res.ok) throw new Error(`读取失败：${path}（HTTP ${res.status}）`)
  return await res.text()
}

export async function putFile(
  client: WebDavClient,
  path: string,
  localPath: string,
) {
  const fm: any = (globalThis as any).FileManager
  if (typeof fm?.readAsData !== "function") {
    throw new Error("当前 Scripting 版本不支持读取二进制文件")
  }
  const data = await fm.readAsData(localPath)
  if (!data) throw new Error(`无法读取文件：${localPath}`)
  const res = await request(client, path, {
    method: "PUT",
    headers: { "Content-Type": "application/octet-stream" },
    body: data,
  })
  if (!res.ok) throw new Error(`上传失败：${path}（HTTP ${res.status}）`)
}

export async function getToFile(
  client: WebDavClient,
  path: string,
  destPath: string,
): Promise<boolean> {
  const fm: any = (globalThis as any).FileManager
  const res = await request(client, path)
  if (res.status === 404) return false
  if (!res.ok) throw new Error(`下载失败：${path}（HTTP ${res.status}）`)
  const data = await res.data()
  if (typeof fm?.writeAsData !== "function") {
    throw new Error("当前 Scripting 版本不支持写入二进制文件")
  }
  await fm.writeAsData(destPath, data)
  return true
}

export async function deleteFile(
  client: WebDavClient,
  path: string,
): Promise<boolean> {
  const res = await request(client, path, { method: "DELETE" })
  if (res.status === 404) return false
  if (!res.ok) throw new Error(`删除失败：${path}（HTTP ${res.status}）`)
  return true
}
