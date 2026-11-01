#!/bin/bash
# 用法：scripts/bundle.sh 1.0.0   → 生成 dist/CoinBar.app 和 dist/CoinBar-1.0.0.zip
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?需要版本号，例如 scripts/bundle.sh 1.0.0}"
BUILD="$(date +%Y%m%d%H%M)"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/CoinBar"

APP="dist/CoinBar.app"
rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CoinBar"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R Resources/CoinIcons "$APP/Contents/Resources/CoinIcons"   # 内置币种图标（大陆连不上图标 CDN）

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.lenka.coinbar</string>
  <key>CFBundleName</key><string>CoinBar</string>
  <key>CFBundleDisplayName</key><string>CoinBar</string>
  <key>CFBundleExecutable</key><string>CoinBar</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

codesign --force --deep --sign - "$APP"   # ad-hoc 签名，Apple Silicon 必需
ditto -c -k --keepParent "$APP" "dist/CoinBar-${VERSION}.zip"
echo "✅ dist/CoinBar-${VERSION}.zip"
