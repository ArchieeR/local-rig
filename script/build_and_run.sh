#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="LocalRig"
MIN_SYSTEM_VERSION="14.0"
APP_VERSION="${LOCAL_RIG_VERSION:-0.1.0}"
BUILD_CONFIGURATION="${LOCAL_RIG_BUILD_CONFIGURATION:-debug}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
TASK_CLANG_CACHE="$ROOT_DIR/.build/clang-module-cache"
TASK_SWIFTPM_CACHE="$ROOT_DIR/.build/swiftpm-module-cache"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
USER_APPLICATIONS_DIR="${LOCAL_RIG_APPLICATIONS_DIR:-${RHEOS_RIG_APPLICATIONS_DIR:-$HOME/Applications}}"
INSTALLED_APP="$USER_APPLICATIONS_DIR/Local Rig.app"
LEGACY_INSTALLED_APP="$USER_APPLICATIONS_DIR/Rheos Rig.app"

# Existing installs retain their designated requirement so macOS does not ask
# for Documents access again. Fresh installs use the public Local Rig identity.
DEFAULT_BUNDLE_ID="app.localrig.LocalRig"
LEGACY_BUNDLE_ID="com.rheos.RheosRig"
EXISTING_BUNDLE_ID=""
if [ -f "$INSTALLED_APP/Contents/Info.plist" ]; then
  EXISTING_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INSTALLED_APP/Contents/Info.plist" 2>/dev/null || true)"
elif [ -f "$LEGACY_INSTALLED_APP/Contents/Info.plist" ]; then
  EXISTING_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$LEGACY_INSTALLED_APP/Contents/Info.plist" 2>/dev/null || true)"
fi
BUNDLE_ID="${LOCAL_RIG_BUNDLE_ID:-${EXISTING_BUNDLE_ID:-$DEFAULT_BUNDLE_ID}}"

if [ "$BUNDLE_ID" = "$LEGACY_BUNDLE_ID" ]; then
  DEFAULT_SIGNING_IDENTITY="Rheos Rig Local Development (Dedicated)"
  DEFAULT_SIGNING_KEYCHAIN="$HOME/Library/Keychains/rheos-rig-local-signing.keychain-db"
  DEFAULT_SIGNING_PASSWORD="rheos-rig-local-signing-only"
else
  DEFAULT_SIGNING_IDENTITY="Local Rig Local Development (Dedicated)"
  DEFAULT_SIGNING_KEYCHAIN="$HOME/Library/Keychains/local-rig-signing.keychain-db"
  DEFAULT_SIGNING_PASSWORD="local-rig-signing-only"
fi
SIGNING_IDENTITY="${LOCAL_RIG_SIGNING_IDENTITY:-${RHEOS_RIG_SIGNING_IDENTITY:-$DEFAULT_SIGNING_IDENTITY}}"
SIGNING_KEYCHAIN="${LOCAL_RIG_SIGNING_KEYCHAIN:-${RHEOS_RIG_SIGNING_KEYCHAIN:-$DEFAULT_SIGNING_KEYCHAIN}}"
SIGNING_KEYCHAIN_PASSWORD="${LOCAL_RIG_SIGNING_KEYCHAIN_PASSWORD:-${RHEOS_RIG_SIGNING_KEYCHAIN_PASSWORD:-$DEFAULT_SIGNING_PASSWORD}}"
SIGNING_MODE="${LOCAL_RIG_SIGNING_MODE:-adhoc}"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

if [ "${LOCAL_RIG_SKIP_STOP:-0}" != "1" ]; then
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  pkill -x "RheosRig" >/dev/null 2>&1 || true
fi

cd "$ROOT_DIR"
export CLANG_MODULE_CACHE_PATH="$TASK_CLANG_CACHE"
export SWIFTPM_MODULECACHE_OVERRIDE="$TASK_SWIFTPM_CACHE"
BUILD_ARGUMENTS=(--disable-sandbox)
if [ "$BUILD_CONFIGURATION" = "release" ]; then
  BUILD_ARGUMENTS+=(-c release)
elif [ "$BUILD_CONFIGURATION" != "debug" ]; then
  echo "error: LOCAL_RIG_BUILD_CONFIGURATION must be debug or release" >&2
  exit 2
fi
swift build "${BUILD_ARGUMENTS[@]}"
BUILD_BINARY="$(swift build "${BUILD_ARGUMENTS[@]}" --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>Local Rig</string>
  <key>CFBundleDisplayName</key>
  <string>Local Rig</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_VERSION</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc signing is deliberately the default: Local Rig must build and run
# without asking for any keychain password. A dedicated identity is strictly
# opt-in via LOCAL_RIG_SIGNING_MODE=dedicated after explicit one-time setup.
SIGNING_IDENTITY_HASH=""
if [ "$SIGNING_MODE" = "dedicated" ] && [ -f "$SIGNING_KEYCHAIN" ] \
  && security unlock-keychain -p "$SIGNING_KEYCHAIN_PASSWORD" "$SIGNING_KEYCHAIN" 2>/dev/null; then
  SIGNING_IDENTITY_HASH="$(
    security find-identity -v -p codesigning "$SIGNING_KEYCHAIN" 2>/dev/null \
      | awk -v identity="$SIGNING_IDENTITY" 'index($0, "\"" identity "\"") { print $2; exit }'
  )"
fi
if [ "$SIGNING_MODE" = "dedicated" ]; then
  if [ -z "$SIGNING_IDENTITY_HASH" ]; then
    echo "error: dedicated signing was requested but its Local Rig identity is unavailable" >&2
    echo "run script/setup_local_signing.sh interactively, or omit LOCAL_RIG_SIGNING_MODE" >&2
    exit 1
  fi
  codesign --force \
    --keychain "$SIGNING_KEYCHAIN" \
    --sign "$SIGNING_IDENTITY_HASH" \
    --identifier "$BUNDLE_ID" \
    "$APP_BUNDLE"
else
  codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP_BUNDLE"
fi
codesign --verify --deep --strict "$APP_BUNDLE"

# Launch from a stable location outside the protected Documents tree. Keeping
# the runnable app inside the source repo can itself trigger Documents access
# before the app's stored privacy grant is considered.
mkdir -p "$USER_APPLICATIONS_DIR"
if [ -e "$INSTALLED_APP" ]; then
  rm -rf "$INSTALLED_APP"
fi
/usr/bin/ditto "$APP_BUNDLE" "$INSTALLED_APP"
codesign --verify --deep --strict "$INSTALLED_APP"
if [ -e "$LEGACY_INSTALLED_APP" ]; then
  rm -rf "$LEGACY_INSTALLED_APP"
fi

open_app() {
  /usr/bin/open -n "$INSTALLED_APP"
}

case "$MODE" in
  --install|install)
    echo "Installed $INSTALLED_APP"
    ;;
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--install|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
