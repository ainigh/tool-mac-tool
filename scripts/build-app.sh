#!/bin/bash
# Builds build/ToolMacTool.app and build/ToolMacTool.zip (what a release carries). Needs a Mac with
# Xcode or its Command Line Tools; GitHub Actions runs it, so nobody has to build anything by hand.
#
#   VERSION=0.1.7 scripts/build-app.sh
#
# The app's "Update" runs it too, on your Mac, when GitHub hasn't built that commit (UNIVERSAL=0:
# just this Mac's chip, which works with only the Command Line Tools).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.0.0-dev}"
COMMIT="${COMMIT:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}"
# The branch the app's updater follows.
BRANCH="${BRANCH:-main}"
NAME=ToolMacTool
APP="build/$NAME.app"

if [[ "${UNIVERSAL:-1}" == 1 ]]; then ARCHS=(--arch arm64 --arch x86_64); else ARCHS=(); fi
swift build -c release ${ARCHS[@]+"${ARCHS[@]}"}
BIN="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/$NAME"

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
  <key>ToolMacToolCommit</key><string>$COMMIT</string>
  <key>ToolMacToolBranch</key><string>$BRANCH</string>
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
echo "built $APP ($VERSION, $BRANCH, $COMMIT)"
