#!/bin/bash
# 金桔 DMG 安装包制作:挂载后呈现经典的"拖入 Applications"布局。
# 用法:./make-dmg.sh [版本号](默认 1.0.0);需先运行 ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-1.0.0}"
APP="build/Kumquat.app"
STAGING="build/dmg-staging"
DMG="build/Kumquat-v$VERSION.dmg"

[ -d "$APP" ] || { echo "未找到 $APP,请先运行 ./build.sh"; exit 1; }

echo "==> 组装 staging(app + Applications 快捷方式)"
rm -rf "$STAGING" "$DMG" "$DMG.sha256"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

echo "==> hdiutil 制作压缩 DMG"
hdiutil create -volname "Kumquat $VERSION" \
               -srcfolder "$STAGING" \
               -ov -format UDZO \
               "$DMG" >/dev/null

echo "==> 计算 SHA-256"
shasum -a 256 "$DMG" > "$DMG.sha256"
cat "$DMG.sha256"

rm -rf "$STAGING"
echo "==> DMG 完成: $DMG"
