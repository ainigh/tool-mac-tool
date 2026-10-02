#!/bin/bash
# Copies the diagram canvas's shared scripts from a Mind Map Studio checkout (the HOME repository):
# its Mermaid reader and its icons, which Sources/ToolMacTool/Network/network.js draws with.
#
#   scripts/sync-network.sh ../HOME
#
# Run it after those files change there; the app ships whatever is in Network/.
set -euo pipefail
cd "$(dirname "$0")/.."
studio="${1:?usage: scripts/sync-network.sh path/to/mind-map-studio}"
for f in icons.js icon-set.js icon-brands.js icon-match.js mermaid.js; do
  cp "$studio/js/$f" "Sources/ToolMacTool/Network/$f"
done
echo "copied from $studio/js into Sources/ToolMacTool/Network"
