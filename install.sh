#!/bin/bash
# Installs (or reinstalls) Tool Mac Tool into ~/Applications, then opens it. After this, updates
# come from the menu.
#
#   gh api -H "Accept: application/vnd.github.raw" repos/ainigh/tool-mac-tool/contents/install.sh | bash
#
# The repository may be private, so everything comes through gh, signed in to GitHub (this sets
# gh up if it's missing). It takes the latest release that GitHub built. If there isn't one (or
# TMT_FROM_SOURCE=1), it downloads the source of main (TMT_BRANCH=name for another branch) and
# builds it here with Apple's command line tools. The app then follows that branch for updates.
set -euo pipefail

REPO="ainigh/tool-mac-tool"
BRANCH="${TMT_BRANCH:-main}"
APPS="$HOME/Applications"
NAME="ToolMacTool"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() { printf '\n\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

# gh, signed in ------------------------------------------------------------------------------
for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do if [[ -x "$b" ]]; then eval "$("$b" shellenv)"; fi; done
if ! command -v gh >/dev/null 2>&1; then
  command -v brew >/dev/null 2>&1 || die "Needs Homebrew (https://brew.sh), then run this again."
  say "Installing gh (GitHub's command line tool)"
  brew install gh
fi
if ! gh api "repos/$REPO" --silent >/dev/null 2>&1; then
  say "Sign in to GitHub with an account that can see $REPO (a browser window opens)"
  gh auth login --web --git-protocol https -h github.com </dev/tty
  gh api "repos/$REPO" --silent >/dev/null 2>&1 || die "That account can't open $REPO."
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# the app: GitHub's build, else built here -----------------------------------------------------
app=""
if [[ "${TMT_FROM_SOURCE:-0}" != 1 && "$BRANCH" == main ]]; then
  say "Downloading the latest release"
  if gh release download --repo "$REPO" --pattern "$NAME.zip" --dir "$tmp" 2>/dev/null; then
    ditto -x -k "$tmp/$NAME.zip" "$tmp/unpacked"
    app="$tmp/unpacked/$NAME.app"
  else
    echo "  No release yet: building it here instead."
  fi
fi

if [[ -z "$app" ]]; then
  xcode-select -p >/dev/null 2>&1 || die "Building needs Apple's command line tools: run xcode-select --install, then this again."
  # build-app.sh finds a Swift 6 toolchain (an installed Xcode will do) or says what to update.
  sha="$(gh api "repos/$REPO/commits/$BRANCH" --jq .sha)" || die "Couldn't find the branch $BRANCH."
  say "Downloading the source ($BRANCH, ${sha:0:7})"
  mkdir -p "$tmp/src"
  gh api "repos/$REPO/tarball/$sha" > "$tmp/src.tar.gz"
  tar -xzf "$tmp/src.tar.gz" -C "$tmp/src" --strip-components 1
  say "Building (a minute or two)"
  (cd "$tmp/src" && VERSION="0.1-${sha:0:7}" COMMIT="$sha" BRANCH="$BRANCH" UNIVERSAL=0 scripts/build-app.sh)
  app="$tmp/src/build/$NAME.app"
fi

# install and open -----------------------------------------------------------------------------
say "Installing into $APPS"
pkill -x "$NAME" 2>/dev/null && sleep 1 || true
mkdir -p "$APPS"
rm -rf "$APPS/$NAME.app"
ditto "$app" "$APPS/$NAME.app"
xattr -dr com.apple.quarantine "$APPS/$NAME.app" 2>/dev/null || true
open "$APPS/$NAME.app"
say "Done: look for the wrench icon in the menu bar."
