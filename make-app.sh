#!/bin/bash
# 组装可双击运行的 "JSONL Analyzer.app"（ad-hoc 签名）。
# 用法: ./make-app.sh [debug|release]   （默认 release）
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN="$(pwd)/.build/$CONFIG/JSONLAnalyzer"

APP="JSONL Analyzer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cp "$BIN" "$APP/Contents/MacOS/JSONLAnalyzer"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>JSONL Analyzer</string>
    <key>CFBundleDisplayName</key>
    <string>JSONL Analyzer</string>
    <key>CFBundleExecutable</key>
    <string>JSONLAnalyzer</string>
    <key>CFBundleIdentifier</key>
    <string>com.v1ki.jsonl-analyzer</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>JSON Lines</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>jsonl</string>
                <string>json</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Zstandard 压缩 JSON Lines</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>zstd</string>
                <string>zst</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || codesign --force - "$APP"
echo "已生成: $(pwd)/$APP"
echo "双击打开，或拖 .jsonl / .zstd 文件到 App 图标。"
