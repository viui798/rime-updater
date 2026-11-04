// 用 URL scheme 让仓输入法 / 元书重新部署。
export type InputMethod = "hamster" | "hamster3" | "none"

export async function deployInputMethod(method: InputMethod): Promise<boolean> {
  if (method === "none") return false
  const url =
    method === "hamster3"
      ? "hamster3://dev.fuxiao.app.hamster3/rime?action=deploy"
      : "hamster://dev.fuxiao.app.hamster/rime?deploy"

  const Safari = (globalThis as any).Safari
  if (typeof Safari?.openURL === "function") {
    return !!(await Safari.openURL(url))
  }
  if (typeof Safari?.open === "function") {
    return (await Safari.open(url)) !== false
  }
  const openURL = (globalThis as any).openURL
  if (typeof openURL === "function") {
    return (await openURL(url)) !== false
  }
  throw new Error("当前 Scripting 版本不支持打开 URL，请手动到输入法里部署")
}
