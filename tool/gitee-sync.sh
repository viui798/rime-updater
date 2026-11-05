#!/usr/bin/env bash
# 把本仓库首次同步到 Gitee：建仓 → 加 remote → 推 main 与标签。
#
# 用法：
#   GITEE_TOKEN=<私人令牌> ./tool/gitee-sync.sh
#   GITEE_TOKEN=<私人令牌> ./tool/gitee-sync.sh <仓库名>      # 默认 rime-updater
#
# 令牌在 Gitee「设置 → 私人令牌」生成，只需勾选 projects 权限。
# 脚本可重复执行：仓库已存在时跳过建仓，推送本身是幂等的。
#
# 不做的两件事（按需手动）：
#   1. Gitee 镜像仓库（从 GitHub 拉取同步）：注意 GitHub 版 .github/workflows/build.yml
#      会在推 v* 标签时构建并建 Release，经镜像推回 Gitee 不会触发 Actions，
#      所以 Gitee 侧不会有 CI 产物，需要单独上传或另配流水线。
#   2. 把 README / AGENTS 里的 GitHub 链接改成 Gitee：多数链接指向第三方或方案源仓库，
#      不该替换，需要逐条判断。
set -euo pipefail

REPO_NAME="${1:-rime-updater}"
GITEE_OWNER="${GITEE_OWNER:-viui798}"
API="https://gitee.com/api/v5"
WEB="https://gitee.com/${GITEE_OWNER}/${REPO_NAME}"

if [[ -z "${GITEE_TOKEN:-}" ]]; then
  echo "缺少 GITEE_TOKEN。到 https://gitee.com/profile/personal_access_tokens 生成后：" >&2
  echo "  GITEE_TOKEN=xxx $0 ${REPO_NAME}" >&2
  exit 1
fi

cd "$(dirname "$0")/.."

echo "==> 1/4 校验令牌与用户名"
# 令牌放请求头而不是 URL，避免出现在错误信息或日志里
resp=$(curl -sS --max-time 20 -H "Authorization: token ${GITEE_TOKEN}" \
  "${API}/user" 2>&1) || {
  echo "连不上 Gitee API：${resp}" >&2
  exit 1
}
me=$(printf '%s' "$resp" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("login",""))' 2>/dev/null || true)
if [[ -z "$me" ]]; then
  echo "令牌无效或没有 projects 权限。API 返回：" >&2
  printf '%s\n' "$resp" | head -c 300 >&2
  echo >&2
  exit 1
fi
echo "    已登录：${me}"
if [[ "$me" != "$GITEE_OWNER" ]]; then
  echo "    注意：令牌属于 ${me}，但目标是 ${GITEE_OWNER}/${REPO_NAME}。"
  echo "    如要用 ${me} 的命名空间，请加 GITEE_OWNER=${me} 重新执行。"
  exit 1
fi

echo "==> 2/4 建仓（已存在则跳过）"
exists=$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' "${API}/repos/${GITEE_OWNER}/${REPO_NAME}")
if [[ "$exists" == "200" ]]; then
  echo "    仓库已存在，跳过建仓"
else
  created=$(curl -sS --max-time 30 -X POST "${API}/user/repos" \
    -H "Authorization: token ${GITEE_TOKEN}" \
    --data-urlencode "name=${REPO_NAME}" \
    --data-urlencode "description=Rime 更新器：检查版本 → 预演变更 → 一键更新 → 需要时回滚" \
    --data-urlencode "private=false" \
    --data-urlencode "has_issues=true" \
    --data-urlencode "has_wiki=false") || {
    echo "建仓请求失败，请检查网络。" >&2
    exit 1
  }
  url=$(printf '%s' "$created" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("html_url") or "")' 2>/dev/null || true)
  if [[ -z "$url" ]]; then
    echo "建仓失败，Gitee 返回：" >&2
    printf '%s\n' "$created" | head -c 300 >&2
    echo >&2
    exit 1
  fi
  echo "    已创建：${url}"
fi

echo "==> 3/4 配置 remote gitee"
if git remote get-url gitee >/dev/null 2>&1; then
  git remote set-url gitee "${WEB}.git"
else
  git remote add gitee "${WEB}.git"
fi
echo "    $(git remote get-url gitee)"

echo "==> 4/4 推送 main 与标签"
git push gitee main
# 只推功能标签，避免把已经废弃的 v1.0.0 残留也带过去
git push gitee v0.10

echo
echo "完成：${WEB}"
echo "提示：README 里的下载链接仍指向 GitHub Releases；Gitee 侧没有 CI 产物。"
