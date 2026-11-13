#!/bin/zsh
# Builds TidyLeft.app into ./build
set -euo pipefail
cd "$(dirname "$0")"

# Universal binary: runs on Apple Silicon and Intel Macs.
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release $ARCHS
BIN="$(swift build -c release $ARCHS --show-bin-path)/TidyLeft"
APP="build/TidyLeft.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TidyLeft"
[[ -f Resources/AppIcon.icns ]] || scripts/make-icns.sh
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>TidyLeft</string>
  <key>CFBundleDisplayName</key><string>TidyLeft</string>
  <key>CFBundleIdentifier</key><string>local.tidyleft</string>
  <key>CFBundleExecutable</key><string>TidyLeft</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built: $PWD/$APP"
