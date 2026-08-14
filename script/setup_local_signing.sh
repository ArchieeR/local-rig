#!/usr/bin/env bash
set -euo pipefail

SIGNING_IDENTITY="${LOCAL_RIG_SIGNING_IDENTITY:-Local Rig Local Development (Dedicated)}"
SIGNING_KEYCHAIN="${LOCAL_RIG_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/local-rig-signing.keychain-db}"
# This password protects only a disposable self-signed development certificate.
# It deliberately does not protect or unlock the user's login keychain.
SIGNING_KEYCHAIN_PASSWORD="${LOCAL_RIG_SIGNING_KEYCHAIN_PASSWORD:-local-rig-signing-only}"

ensure_search_list() {
    if security list-keychains -d user | grep -Fq "\"$SIGNING_KEYCHAIN\""; then
        return
    fi

    local existing_keychains=()
    local keychain
    while IFS= read -r keychain; do
        keychain="${keychain#*\"}"
        keychain="${keychain%\"*}"
        if [ -n "$keychain" ]; then
            existing_keychains+=("$keychain")
        fi
    done < <(security list-keychains -d user)
    security list-keychains -d user -s "${existing_keychains[@]}" "$SIGNING_KEYCHAIN"
}

if [ -f "$SIGNING_KEYCHAIN" ] && security find-identity -v -p codesigning "$SIGNING_KEYCHAIN" 2>/dev/null | grep -Fq "\"$SIGNING_IDENTITY\""; then
    if security unlock-keychain -p "$SIGNING_KEYCHAIN_PASSWORD" "$SIGNING_KEYCHAIN" 2>/dev/null; then
        ensure_search_list
        exit 0
    fi
    # This keychain contains only Local Rig's disposable self-signed identity.
    # If its configured password no longer unlocks it, recreate it rather than
    # leaving every subsequent build unable to sign or launch the app.
    security delete-keychain "$SIGNING_KEYCHAIN"
fi

SIGNING_TEMP_DIR="$(mktemp -d /private/tmp/local-rig-signing.XXXXXX)"
cleanup() {
    rm -rf "$SIGNING_TEMP_DIR"
}
trap cleanup EXIT

PRIVATE_KEY="$SIGNING_TEMP_DIR/private-key.pem"
CERTIFICATE="$SIGNING_TEMP_DIR/certificate.pem"
IDENTITY_BUNDLE="$SIGNING_TEMP_DIR/identity.p12"

mkdir -p "$(dirname "$SIGNING_KEYCHAIN")"
if [ -f "$SIGNING_KEYCHAIN" ]; then
    security delete-keychain "$SIGNING_KEYCHAIN"
fi

security create-keychain -p "$SIGNING_KEYCHAIN_PASSWORD" "$SIGNING_KEYCHAIN"
security set-keychain-settings -lut 21600 "$SIGNING_KEYCHAIN"
security unlock-keychain -p "$SIGNING_KEYCHAIN_PASSWORD" "$SIGNING_KEYCHAIN"

/opt/homebrew/bin/openssl req \
    -new \
    -newkey rsa:2048 \
    -nodes \
    -x509 \
    -days 3650 \
    -subj "/C=GB/O=Local Rig/CN=$SIGNING_IDENTITY" \
    -addext "basicConstraints=critical,CA:true" \
    -addext "keyUsage=critical,digitalSignature,keyCertSign" \
    -addext "extendedKeyUsage=codeSigning" \
    -keyout "$PRIVATE_KEY" \
    -out "$CERTIFICATE" \
    >/dev/null 2>&1

/opt/homebrew/bin/openssl pkcs12 \
    -export \
    -legacy \
    -inkey "$PRIVATE_KEY" \
    -in "$CERTIFICATE" \
    -name "$SIGNING_IDENTITY" \
    -passout "pass:$SIGNING_KEYCHAIN_PASSWORD" \
    -out "$IDENTITY_BUNDLE"

security import "$IDENTITY_BUNDLE" \
    -k "$SIGNING_KEYCHAIN" \
    -P "$SIGNING_KEYCHAIN_PASSWORD" \
    -T /usr/bin/codesign \
    >/dev/null
security add-trusted-cert \
    -r trustRoot \
    -p codeSign \
    -k "$SIGNING_KEYCHAIN" \
    "$CERTIFICATE"
security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s \
    -k "$SIGNING_KEYCHAIN_PASSWORD" \
    "$SIGNING_KEYCHAIN" \
    >/dev/null

security find-identity -v -p codesigning "$SIGNING_KEYCHAIN" | grep -F "\"$SIGNING_IDENTITY\"" >/dev/null
ensure_search_list
echo "Created prompt-free local signing identity in $SIGNING_KEYCHAIN"
