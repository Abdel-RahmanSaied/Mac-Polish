#!/bin/zsh
# Release workflow: imports the signing identity backup into a new temporary keychain, so packaged builds
# meet the same designated requirement as local builds and users keep their permissions after updating.
# Usage: Scripts/import-signing-identity.sh <identity.p12> <new keychain path>
#   MACPOLISH_SIGNING_P12_PASSWORD  the backup's password (from create-signing-identity.sh --export).
# Prints the identity name. Sign with MACPOLISH_SIGN_IDENTITY=<name> MACPOLISH_SIGN_KEYCHAIN=<keychain path>.
set -euo pipefail
P12="${1:?Usage: import-signing-identity.sh <identity.p12> <keychain>}"
KEYCHAIN="${2:?Usage: import-signing-identity.sh <identity.p12> <keychain>}"
[[ ! -e "$KEYCHAIN" ]] || { print -u2 "Refusing to reuse an existing keychain: $KEYCHAIN"; exit 1; }
KEYCHAIN_PASSWORD="$(/usr/bin/openssl rand -hex 24)"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 3600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
# --keychain on codesign restricts certificate lookup; private-key lookup also uses this list.
typeset -a SEARCH_KEYCHAINS
SEARCH_KEYCHAINS=("${(@f)$(security list-keychains -d user | sed 's/^ *"//; s/"$//')}")
security list-keychains -d user -s "$KEYCHAIN" "${SEARCH_KEYCHAINS[@]}"
[[ -n "${MACPOLISH_SIGNING_P12_PASSWORD:-}" ]] || { print -u2 "Set the encrypted backup password."; exit 1; }
security import "$P12" -k "$KEYCHAIN" -P "$MACPOLISH_SIGNING_P12_PASSWORD" -T /usr/bin/codesign >/dev/null
# This keychain holds only the imported identity, so allowing codesign for all its keys is scoped to it.
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
NAME="$(security find-identity -p codesigning "$KEYCHAIN" | sed -n 's/^ *[0-9]*) [0-9A-F]* "\(.*\)".*/\1/p' | head -1)"
[[ -n "$NAME" ]] || { print -u2 "No code signing identity found in $P12."; exit 1; }
print -r -- "$NAME"
