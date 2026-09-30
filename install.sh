#!/bin/bash
# Installs (or reinstalls) Tool Mac Tool into ~/Applications, then opens it. After this, updates
# come from the menu (Check for updates).
#
#   curl -fsSL https://raw.githubusercontent.com/ainigh/tool-mac-tool/main/install.sh | bash
#
# It takes the latest release that GitHub built. If there isn't one (or TMT_FROM_SOURCE=1), it
# downloads the source of main (TMT_BRANCH=name for another branch) and builds it here with
# Apple's command line tools.
set -euo pipefail

REPO="ainigh/tool-mac-tool"
BRANCH="${TMT_BRANCH:-main}"
APPS="$HOME/Applications"
NAME="ToolMacTool"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() { printf '\n\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

app=""
if [[ "${TMT_FROM_SOURCE:-0}" != 1 && "$BRANCH" == main ]]; then
  say "Downloading the latest release"
  if curl -fsSL -o "$tmp/$NAME.zip" "https://github.com/$REPO/releases/latest/download/$NAME.zip"; then
    ditto -x -k "$tmp/$NAME.zip" "$tmp/unpacked"
    app="$tmp/unpacked/$NAME.app"
  else
    echo "  No release yet: building it here instead."
  fi
fi

if [[ -z "$app" ]]; then
  xcode-select -p >/dev/null 2>&1 || die "Building needs Apple's command line tools: run xcode-select --install, then this again."
  say "Downloading the source ($BRANCH)"
  mkdir -p "$tmp/src"
  curl -fsSL "https://codeload.github.com/$REPO/tar.gz/refs/heads/$BRANCH" | tar -xz -C "$tmp/src" --strip-components 1
  sha="$(curl -fsSL -H 'Accept: application/vnd.github.sha' "https://api.github.com/repos/$REPO/commits/$BRANCH" || echo unknown)"
  say "Building (a minute or two)"
  (cd "$tmp/src" && VERSION="0.1-${sha:0:7}" COMMIT="$sha" UNIVERSAL=0 scripts/build-app.sh)
  app="$tmp/src/build/$NAME.app"
fi

say "Installing into $APPS"
pkill -x "$NAME" 2>/dev/null && sleep 1 || true
mkdir -p "$APPS"
rm -rf "$APPS/$NAME.app"
ditto "$app" "$APPS/$NAME.app"
xattr -dr com.apple.quarantine "$APPS/$NAME.app" 2>/dev/null || true
open "$APPS/$NAME.app"
say "Done: look for the wrench icon in the menu bar."
