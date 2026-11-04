#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_TARGET="/Users/rm/Documents/!Projects/Golosok-Build/Golosok-Dev.app"

echo "==> Компиляция Golosok-Dev..."
swiftc -parse-as-library -target arm64-apple-macos14.0 -O \
    -sdk "$(xcrun --show-sdk-path)" \
    "$DIR"/Golosok/*.swift \
    -o "$APP_TARGET/Contents/MacOS/Golosok"

echo "==> Обновление версии в Info.plist с суффиксом -dev..."
BASE_VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_TARGET/Contents/Info.plist" 2>/dev/null || echo "1.13.9")
CLEAN_VER="${BASE_VER%-dev}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${CLEAN_VER}-dev" "$APP_TARGET/Contents/Info.plist"

echo "==> Подписание ad-hoc сигнатурой..."
xattr -cr "$APP_TARGET"
codesign --force --deep --sign - "$APP_TARGET"

echo "==> Готово: $APP_TARGET (v${CLEAN_VER}-dev)"
