#!/bin/bash
# 把已构建的 RimeUpdater.app 打包成 DMG（拖到「应用程序」即可安装）。
# 用法：cd app && ./tool/make_dmg.sh [版本号]
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-1.0.0}"
APP="build/macos/Build/Products/Release/RimeUpdater.app"
OUT="build/RimeUpdater-v${VERSION}-macos.dmg"

if [ ! -d "$APP" ]; then
  echo "找不到 $APP，请先执行 flutter build macos"
  exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create \
  -volname "RimeUpdater" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$OUT" >/dev/null

hdiutil verify "$OUT" >/dev/null
echo "已生成 $OUT ($(du -h "$OUT" | cut -f1))"
echo "提示：未签名/未公证的 app 首次打开需右键选择「打开」。"
