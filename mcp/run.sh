#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if command -v node >/dev/null 2>&1; then
  NODE_BINARY="$(command -v node)"
elif [ -x /opt/homebrew/bin/node ]; then
  NODE_BINARY=/opt/homebrew/bin/node
elif [ -x /usr/local/bin/node ]; then
  NODE_BINARY=/usr/local/bin/node
else
  echo "Local Rig MCP requires Node.js 18 or newer." >&2
  exit 1
fi

exec "$NODE_BINARY" "$HERE/server.mjs"
