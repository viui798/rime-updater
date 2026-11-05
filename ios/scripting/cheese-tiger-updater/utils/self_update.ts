// 脚本自身更新检查：对比远端 script.json 的 version 与本地 SCRIPT_VERSION。
//
// 更新动作交给 Scripting 自己完成（script.json 的 remoteResource 带 autoUpdateInterval），
// 这里只负责「告诉用户有没有新版本」并打开脚本页面，避免在没有官方 API 的前提下
// 去覆盖 Scripting 的脚本目录。
import { SCRIPT_VERSION } from "./config"
import { Runtime } from "./runtime"

export const SELF_REPO = "viui798/rime-updater"

/** 脚本在 GitHub 上的目录页，用户在 Scripting 里用这个地址导入 / 更新。 */
export const SCRIPT_PAGE_URL =
  "https://github.com/viui798/rime-updater/tree/main/ios/scripting/cheese-tiger-updater"

const META_URL =
  "https://raw.githubusercontent.com/viui798/rime-updater/main/ios/scripting/cheese-tiger-updater/script.json"

export type SelfUpdateInfo = {
  current: string
  latest: string
  hasUpdate: boolean
  url: string
}

/** 逐段比较版本号，返回 1 / 0 / -1。 */
export function compareVersion(a: string, b: string): number {
  const pa = String(a ?? "").split(".").map((n) => parseInt(n, 10) || 0)
  const pb = String(b ?? "").split(".").map((n) => parseInt(n, 10) || 0)
  const len = Math.max(pa.length, pb.length)
  for (let i = 0; i < len; i += 1) {
    const x = pa[i] ?? 0
    const y = pb[i] ?? 0
    if (x !== y) return x > y ? 1 : -1
  }
  return 0
}

/** 读取远端 script.json，与本地版本比较。 */
export async function checkScriptUpdate(): Promise<SelfUpdateInfo> {
  const res = await Runtime.fetch(META_URL, {
    headers: { Accept: "application/json", "Cache-Control": "no-cache" },
  })
  if (!res.ok) {
    throw new Error(`无法读取远端脚本信息（HTTP ${res.status}）`)
  }
  const json = await res.json()
  const latest = String(json?.version ?? "").trim()
  if (!latest) throw new Error("远端 script.json 缺少 version 字段")
  return {
    current: SCRIPT_VERSION,
    latest,
    hasUpdate: compareVersion(latest, SCRIPT_VERSION) > 0,
    url: String(json?.remoteResource?.url ?? SCRIPT_PAGE_URL),
  }
}

/** 打开脚本的 GitHub 页面（Scripting 里可从该地址检查 / 重新导入）。 */
export async function openScriptPage(url: string = SCRIPT_PAGE_URL): Promise<boolean> {
  const Safari = Runtime.Safari
  try {
    if (typeof Safari?.openURL === "function") return !!(await Safari.openURL(url))
    if (typeof Safari?.open === "function") return (await Safari.open(url)) !== false
  } catch {
    return false
  }
  return false
}
