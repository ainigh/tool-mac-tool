#!/bin/bash
# Builds build/ToolMacTool.app and build/ToolMacTool.zip (what a release carries). Needs a Mac with
# Xcode or its Command Line Tools; GitHub Actions runs it, so nobody has to build anything by hand.
#
#   VERSION=0.1.7 scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.0.0-dev}"
NAME=ToolMacTool
APP="build/$NAME.app"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/$NAME"

rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$NAME"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.ainigh.toolmactool</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>Tool Mac Tool</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSDesktopFolderUsageDescription</key><string>To move a download's contents into its folder on the Desktop.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>To find your latest download.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature: Apple silicon only runs signed code, and this needs no developer account.
codesign --force --sign - --timestamp=none "$APP"
ditto -c -k --keepParent "$APP" "build/$NAME.zip"
echo "built $APP ($VERSION)"
