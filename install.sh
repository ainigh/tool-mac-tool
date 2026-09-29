#!/bin/bash
# Installs (or reinstalls) Tool Mac Tool: the latest release, into ~/Applications, then opens it.
# After this, updates come from the menu (Check for updates).
#
# The repository is private, so it downloads with gh, signed in to GitHub:
#   gh api -H "Accept: application/vnd.github.raw" repos/ainigh/tool-mac-tool/contents/install.sh | bash
set -euo pipefail

REPO="ainigh/tool-mac-tool"
APPS="$HOME/Applications"
NAME="ToolMacTool"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() { printf '\n\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

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

say "Downloading the latest release"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
gh release download --repo "$REPO" --pattern "$NAME.zip" --dir "$tmp" \
  || die "No release yet: it's made when something is merged into main."

say "Installing into $APPS"
pkill -x "$NAME" 2>/dev/null && sleep 1 || true
mkdir -p "$APPS"
rm -rf "$APPS/$NAME.app"
ditto -x -k "$tmp/$NAME.zip" "$APPS"
xattr -dr com.apple.quarantine "$APPS/$NAME.app" 2>/dev/null || true
open "$APPS/$NAME.app"
say "Done: look for the wrench icon in the menu bar."
