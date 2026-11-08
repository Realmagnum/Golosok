#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_TARGET="/Users/rm/Documents/!Projects/Golosok-Build/Golosok-Dev.app"

echo "==> Компиляция Golosok-Dev..."
swiftc -parse-as-library -target arm64-apple-macos14.0 -O \
    -sdk "$(xcrun --show-sdk-path)" \
    "$DIR"/Golosok/*.swift \
    -o "$APP_TARGET/Contents/MacOS/Golosok"

echo "==> Генерация локализаций из Localizable.xcstrings..."
python3 - << 'PYEOF'
import json, os

src = "/Users/rm/Documents/!Projects/Golosok/Golosok/Localizable.xcstrings"
with open(src) as f:
    d = json.load(f)

en_dict = {}
ru_dict = {}

for k, item in d.get("strings", {}).items():
    locs = item.get("localizations", {})
    if "en" in locs and "stringUnit" in locs["en"]:
        en_dict[k] = locs["en"]["stringUnit"].get("value", k)
    if "ru" in locs and "stringUnit" in locs["ru"]:
        ru_dict[k] = locs["ru"]["stringUnit"].get("value", k)
    else:
        ru_dict[k] = k

def save_strings(data, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        for k in sorted(data.keys()):
            v = data[k]
            k_esc = k.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')
            v_esc = v.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')
            f.write(f'"{k_esc}" = "{v_esc}";\n')

res_dir = "/Users/rm/Documents/!Projects/Golosok-Build/Golosok-Dev.app/Contents/Resources"
save_strings(en_dict, os.path.join(res_dir, "en.lproj/Localizable.strings"))
save_strings(ru_dict, os.path.join(res_dir, "ru.lproj/Localizable.strings"))
print(f"Generated Localizable.strings: en={len(en_dict)}, ru={len(ru_dict)}")
PYEOF

echo "==> Обновление версии в Info.plist с суффиксом -dev..."
BASE_VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_TARGET/Contents/Info.plist" 2>/dev/null || echo "1.13.9")
CLEAN_VER="${BASE_VER%-dev}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${CLEAN_VER}-dev" "$APP_TARGET/Contents/Info.plist"

echo "==> Подписание ad-hoc сигнатурой..."
xattr -cr "$APP_TARGET"
codesign --force --deep --sign - "$APP_TARGET"

echo "==> Готово: $APP_TARGET (v${CLEAN_VER}-dev)"
