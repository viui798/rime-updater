// Release 读取：可指定任意 owner/repo 仓库；优先 -update.zip，没有则用完整包。
import { Runtime } from "./runtime"

export type ReleaseAsset = {
  name: string
  url: string
  size: number
}

export type ReleaseInfo = {
  version: string
  tag: string
  chosen: ReleaseAsset
  assets: ReleaseAsset[]
  publishedAt: string
  body: string
}

export const DEFAULT_REPO = "viui798/viui-tiger-sentense"

/** 给 GitHub Release 资产地址加镜像前缀；不是 GitHub 地址或没配置时原样返回。 */
export function applyMirror(mirror: string | undefined, url: string): string {
  const trimmed = String(mirror ?? "").trim()
  if (!trimmed || !url.startsWith("https://github.com/")) return url
  const base = trimmed.endsWith("/") ? trimmed : `${trimmed}/`
  return `${base}${url}`
}

/**
 * 直链 504 / 超时时的兜底：用 API 查到该资产的下载地址。
 * 只在主链失败后调用，避免白白消耗 API 额度。
 */
export async function fetchAssetApiUrl(
  url: string,
  token?: string,
  repo?: string,
): Promise<string | null> {
  const hit = url.match(
    /^https:\/\/github\.com\/[^/]+\/[^/]+\/releases\/download\/([^/]+)\/([^/?#]+)/,
  )
  if (!hit) return null
  const tag = decodeURIComponent(hit[1])
  const name = decodeURIComponent(hit[2])
  const headers: Record<string, string> = {
    "User-Agent": "cheese-tiger-updater",
    Accept: "application/vnd.github+json",
  }
  if (token && token.trim()) headers.Authorization = `Bearer ${token.trim()}`
  try {
    const res = await Runtime.fetch(
      `https://api.github.com/repos/${parseRepo(repo)}/releases/tags/${tag}`,
      { headers },
    )
    if (!res.ok) return null
    const json = await res.json()
    const assets: any[] = Array.isArray(json?.assets) ? json.assets : []
    const asset = assets.find((item) => item?.name === name)
    const apiUrl = asset?.url ? String(asset.url) : ""
    return apiUrl || null
  } catch {
    return null
  }
}

/** 接受 owner/repo 或 GitHub 网址，返回 owner/repo */
export function parseRepo(input?: string): string {
  const raw = String(input ?? "").trim()
  if (!raw) return DEFAULT_REPO
  const fromUrl = raw.match(/github\.com\/([^/]+)\/([^/?#]+)/i)
  if (fromUrl) return `${fromUrl[1]}/${fromUrl[2].replace(/\.git$/, "")}`
  const plain = raw.match(/^([\w.-]+)\/([\w.-]+)$/)
  if (plain) return `${plain[1]}/${plain[2]}`
  return DEFAULT_REPO
}

function pickAsset(assets: ReleaseAsset[], preferredName?: string): ReleaseAsset | null {
  const preferred = String(preferredName ?? "").trim()
  if (preferred) {
    const hit = assets.find((asset) => asset.name === preferred)
    if (hit) return hit
  }
  const delta = assets.find((asset) => asset.name.endsWith("-update.zip"))
  const full = assets.find(
    (asset) =>
      asset.name.toLowerCase().endsWith(".zip") &&
      !asset.name.endsWith("-update.zip"),
  )
  return delta ?? full ?? null
}

export async function fetchLatest(
  token?: string,
  repo?: string,
  preferredName?: string,
): Promise<ReleaseInfo> {
  const headers: Record<string, string> = {
    "User-Agent": "cheese-tiger-updater",
    Accept: "application/vnd.github+json",
  }
  if (token && token.trim()) {
    headers.Authorization = `Bearer ${token.trim()}`
  }

  const full = parseRepo(repo)
  const res = await Runtime.fetch(
    `https://api.github.com/repos/${full}/releases/latest`,
    { headers },
  )
  if (!res.ok) {
    let detail = `HTTP ${res.status}`
    try {
      const json = await res.json()
      if (json?.message) detail = String(json.message)
    } catch {}
    throw new Error(`无法访问 GitHub Release（${full}）：${detail}`)
  }

  const json = await res.json()
  const tag = String(json?.tag_name ?? "")
  const version = tag.replace(/^v/, "")
  const assets: ReleaseAsset[] = (json?.assets ?? [])
    .filter((asset: any) => asset?.name && asset?.browser_download_url)
    .map((asset: any) => ({
      name: String(asset.name),
      url: String(asset.browser_download_url),
      size: Number(asset.size ?? 0),
    }))

  const chosen = pickAsset(assets, preferredName)
  if (!chosen) throw new Error("Release 里没有可用的 zip 资产")
  return {
    version,
    tag,
    chosen,
    assets,
    publishedAt: String(json?.published_at ?? ""),
    body: String(json?.body ?? ""),
  }
}
