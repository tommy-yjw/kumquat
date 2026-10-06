#!/bin/bash
# 金桔 / Kumquat —— 一条命令从源码构建 Kumquat.app
# 依赖:仅 Xcode Command Line Tools(swiftc);不依赖 Xcode 工程、第三方包。
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Kumquat"
ARCH="$(uname -m)"                 # arm64 或 x86_64(按构建机)
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

echo "==> 清理并创建 bundle 结构"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> swiftc 编译($ARCH,最低 macOS 13)"
swiftc \
    -O \
    -swift-version 5 \
    -target "$ARCH-apple-macos13.0" \
    -framework AppKit -framework SwiftUI -framework UserNotifications \
    Sources/*.swift \
    -o "$APP/Contents/MacOS/$APP_NAME"

echo "==> 写入 Info.plist 与资源"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# ad-hoc 签名:本地运行/通知中心需要合法 bundle;正式分发换成 Developer ID 证书再公证
if command -v codesign >/dev/null 2>&1; then
    echo "==> codesign(ad-hoc)"
    codesign --force --sign - "$APP" || echo "warning: codesign 失败,继续(未签名 bundle)"
fi

echo "==> 构建完成:$PWD/$APP"
