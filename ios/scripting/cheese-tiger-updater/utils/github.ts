// 芝士虎整 Release 读取：优先 -update.zip，没有则用完整包。
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

const OWNER = "viui798"
const REPO = "viui-tiger-sentense"

export async function fetchLatest(token?: string): Promise<ReleaseInfo> {
  const headers: Record<string, string> = {
    "User-Agent": "cheese-tiger-updater",
    Accept: "application/vnd.github+json",
  }
  if (token && token.trim()) {
    headers.Authorization = `Bearer ${token.trim()}`
  }

  const res = await Runtime.fetch(
    `https://api.github.com/repos/${OWNER}/${REPO}/releases/latest`,
    { headers },
  )
  if (!res.ok) {
    let detail = `HTTP ${res.status}`
    try {
      const json = await res.json()
      if (json?.message) detail = String(json.message)
    } catch {}
    throw new Error(`无法访问 GitHub Release：${detail}`)
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

  const delta = assets.find((asset) => asset.name.endsWith("-update.zip"))
  const full = assets.find(
    (asset) =>
      asset.name.toLowerCase().endsWith(".zip") &&
      !asset.name.endsWith("-update.zip"),
  )
  const chosen = delta ?? full
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
