#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE=""
INSTALL_CODEX=1
LAUNCH_APP=1
CHECK_ONLY=0

usage() {
  cat <<'USAGE'
usage: ./script/install.sh --workspace /path/to/rheos-repos [options]

Options:
  --no-codex   Do not register the global Codex MCP.
  --no-launch  Install without opening Local Rig.
  --check      Validate prerequisites and print the install plan without writing.
  -h, --help   Show this help.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --workspace)
      [ "$#" -ge 2 ] || { echo "error: --workspace needs a path" >&2; exit 2; }
      WORKSPACE="$2"
      shift 2
      ;;
    --no-codex)
      INSTALL_CODEX=0
      shift
      ;;
    --no-launch)
      LAUNCH_APP=0
      shift
      ;;
    --check)
      CHECK_ONLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ -z "$WORKSPACE" ]; then
  CANDIDATE="$(cd "$ROOT_DIR/.." && pwd -P)"
  if [ -f "$CANDIDATE/scripts/rig2.sh" ] || [ -f "$CANDIDATE/scripts/qa-rig.sh" ]; then
    WORKSPACE="$CANDIDATE"
  else
    echo "error: pass --workspace with the folder containing scripts/rig2.sh" >&2
    exit 2
  fi
fi

WORKSPACE="$(cd "$WORKSPACE" && pwd -P)"
if [ ! -f "$WORKSPACE/scripts/rig2.sh" ] && [ ! -f "$WORKSPACE/scripts/qa-rig.sh" ]; then
  echo "error: workspace must contain scripts/rig2.sh or scripts/qa-rig.sh: $WORKSPACE" >&2
  exit 2
fi

if [ "$(uname -s)" != "Darwin" ]; then
  echo "error: Local Rig requires macOS" >&2
  exit 1
fi
if [ "$(uname -m)" != "arm64" ]; then
  echo "error: this internal build currently supports Apple silicon Macs only" >&2
  exit 1
fi

MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if [ "$MACOS_MAJOR" -lt 14 ]; then
  echo "error: Local Rig requires macOS 14 or newer" >&2
  exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "error: Apple Command Line Tools or Xcode is required to build Local Rig locally" >&2
  echo "install it with: xcode-select --install" >&2
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "error: Node.js 18 or newer is required for the Local Rig MCP" >&2
  exit 1
fi
NODE_MAJOR="$(node -p 'Number(process.versions.node.split(".")[0])')"
if [ "$NODE_MAJOR" -lt 18 ]; then
  echo "error: Node.js 18 or newer is required; found $(node --version)" >&2
  exit 1
fi

APPLICATIONS_DIR="${LOCAL_RIG_APPLICATIONS_DIR:-$HOME/Applications}"
APP_PATH="$APPLICATIONS_DIR/Local Rig.app"
SUPPORT_ROOT="${LOCAL_RIG_APP_SUPPORT_DIR:-$HOME/Library/Application Support/Local Rig}"
MCP_INSTALL="$SUPPORT_ROOT/MCP"
MCP_RUNNER="$MCP_INSTALL/run.sh"
SKILL_SOURCE="$ROOT_DIR/integrations/skills/rig/SKILL.md"

echo "Local Rig install plan"
echo "  Workspace: $WORKSPACE"
echo "  App:       $APP_PATH"
echo "  MCP:       $MCP_INSTALL"
echo "  Lean mode: enabled"
echo "  Claude:    project MCP + /rig skill"
echo "  Codex:     $([ "$INSTALL_CODEX" -eq 1 ] && echo 'global MCP + workspace skill' || echo 'workspace skill only')"

if [ "$CHECK_ONLY" -eq 1 ]; then
  echo "Prerequisites look good. No files were changed."
  exit 0
fi

mkdir -p "$SUPPORT_ROOT"
MCP_STAGING="$SUPPORT_ROOT/MCP.installing.$$"
trap 'rm -rf "$MCP_STAGING"' EXIT
mkdir -p "$MCP_STAGING"
cp "$ROOT_DIR/mcp/package.json" "$ROOT_DIR/mcp/package-lock.json" "$ROOT_DIR/mcp/server.mjs" "$ROOT_DIR/mcp/run.sh" "$MCP_STAGING/"
chmod +x "$MCP_STAGING/run.sh"
(cd "$MCP_STAGING" && npm ci --omit=dev)
rm -rf "$MCP_INSTALL"
mv "$MCP_STAGING" "$MCP_INSTALL"
trap - EXIT

LOCAL_RIG_BUNDLE_ID=app.localrig.LocalRig \
LOCAL_RIG_BUILD_CONFIGURATION=release \
LOCAL_RIG_APPLICATIONS_DIR="$APPLICATIONS_DIR" \
  "$ROOT_DIR/script/build_and_run.sh" --install

/usr/bin/defaults write app.localrig.LocalRig workspaceRoot -string "$WORKSPACE"
/usr/bin/defaults write app.localrig.LocalRig leanMode -bool true

node "$ROOT_DIR/script/configure_connectors.mjs" \
  --workspace "$WORKSPACE" \
  --mcp-runner "$MCP_RUNNER" \
  --skill "$SKILL_SOURCE"

if [ "$INSTALL_CODEX" -eq 1 ]; then
  if command -v codex >/dev/null 2>&1; then
    codex mcp remove local-rig >/dev/null 2>&1 || true
    codex mcp add --env "LOCAL_RIG_WORKSPACE_ROOT=$WORKSPACE" local-rig -- "$MCP_RUNNER"
  else
    echo "warning: Codex CLI was not found; its MCP was not registered" >&2
  fi
fi

if [ "$LAUNCH_APP" -eq 1 ]; then
  /usr/bin/open "$APP_PATH"
fi

echo
echo "Local Rig is ready. Claude Code should be restarted from $WORKSPACE so it reloads the project MCP and /rig skill."
