#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/local-rig-package.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT

LOCAL_RIG_BUNDLE_ID=app.localrig.LocalRig \
LOCAL_RIG_BUILD_CONFIGURATION=release \
LOCAL_RIG_APPLICATIONS_DIR="$STAGING_DIR" \
LOCAL_RIG_SKIP_STOP=1 \
  "$ROOT_DIR/script/build_and_run.sh" --install

ARTIFACT="$ROOT_DIR/dist/Local-Rig-internal-arm64.zip"
rm -f "$ARTIFACT"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$STAGING_DIR/Local Rig.app" "$ARTIFACT"

codesign --verify --deep --strict "$STAGING_DIR/Local Rig.app"
echo "Created $ARTIFACT"

if git -C "$ROOT_DIR" rev-parse --verify HEAD >/dev/null 2>&1; then
  SOURCE_ARTIFACT="$ROOT_DIR/dist/Local-Rig-Hugo-source.zip"
  rm -f "$SOURCE_ARTIFACT"
  git -C "$ROOT_DIR" archive --format=zip --prefix=rheos-rig/ --output="$SOURCE_ARTIFACT" HEAD
  echo "Created $SOURCE_ARTIFACT"
fi

echo "This internal archive is ad-hoc signed unless LOCAL_RIG_SIGNING_MODE=dedicated was supplied."
echo "A public download still requires a Developer ID signature and Apple notarization."
