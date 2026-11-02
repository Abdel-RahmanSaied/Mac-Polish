#!/bin/bash
set -euo pipefail

# Pinned release: review this script before running it.
VERSION="0.8.0"
REPOSITORY="Abdel-RahmanSaied/Mac-Polish"
ASSET="Mac-Polish-${VERSION}-macos-arm64.zip"
BASE_URL="https://github.com/${REPOSITORY}/releases/download/v${VERSION}"
VERIFY_ONLY=false
if [ "${1:-}" = "--verify-only" ]; then
    VERIFY_ONLY=true
elif [ "$#" -ne 0 ]; then
    echo "Usage: bash install.sh [--verify-only]" >&2
    exit 1
fi

[ "$(uname -s)" = "Darwin" ] || { echo "Mac Polish requires macOS." >&2; exit 1; }
[ "$(uname -m)" = "arm64" ] || { echo "This release requires native Apple Silicon (arm64). Intel and Rosetta terminals are not supported." >&2; exit 1; }
OS_VERSION="$(sw_vers -productVersion)"
[ "${OS_VERSION%%.*}" -ge 14 ] || { echo "macOS 14 or later is required." >&2; exit 1; }
if [ "$VERIFY_ONLY" = false ] && pgrep -x MacPolish >/dev/null; then
    echo "Quit Mac Polish before installing or updating." >&2
    exit 1
fi

STAGING="$(mktemp -d -t mac-polish-install)"
trap 'rm -rf -- "$STAGING"' EXIT
echo "Downloading Mac Polish ${VERSION}…"
curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 "$BASE_URL/$ASSET" -o "$STAGING/$ASSET"
curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 "$BASE_URL/SHA256SUMS.txt" -o "$STAGING/SHA256SUMS.txt"
EXPECTED="$(awk -v asset="$ASSET" '$2 == asset { print $1 }' "$STAGING/SHA256SUMS.txt")"
[[ "$EXPECTED" =~ ^[0-9a-f]{64}$ ]] || { echo "Missing or invalid checksum." >&2; exit 1; }
ACTUAL="$(shasum -a 256 "$STAGING/$ASSET" | awk '{print $1}')"
[ "$EXPECTED" = "$ACTUAL" ] || { echo "Checksum verification failed." >&2; exit 1; }
ditto -x -k "$STAGING/$ASSET" "$STAGING/unpacked"
APP="$STAGING/unpacked/Mac Polish.app"
codesign --verify --deep --strict "$APP"
IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[ "$IDENTIFIER" = "com.asaied.macpolish" ] && [ "$BUNDLE_VERSION" = "$VERSION" ] || { echo "Unexpected application identity or version." >&2; exit 1; }
lipo "$APP/Contents/MacOS/MacPolish" -verify_arch arm64
echo "Download, checksum, application signature and architecture verified."
if [ "$VERIFY_ONLY" = true ]; then exit 0; fi

if pgrep -x MacPolish >/dev/null; then
    echo "Mac Polish started during download. Quit it before installing." >&2
    exit 1
fi
INSTALL_DIRECTORY="$HOME/Applications"
DESTINATION="$INSTALL_DIRECTORY/Mac Polish.app"
mkdir -p "$INSTALL_DIRECTORY"
BACKUP=""
if [ -e "$DESTINATION" ] || [ -L "$DESTINATION" ]; then
    [ ! -L "$DESTINATION" ] || { echo "Refusing to replace a symbolic link." >&2; exit 1; }
    EXISTING_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DESTINATION/Contents/Info.plist" 2>/dev/null || true)"
    [ "$EXISTING_ID" = "com.asaied.macpolish" ] || { echo "An unrelated app already exists at $DESTINATION." >&2; exit 1; }
    BACKUP="$(mktemp -d "$INSTALL_DIRECTORY/MacPolish-backup.XXXXXX")"
    mv "$DESTINATION" "$BACKUP/Mac Polish.app"
fi
if ! mv "$APP" "$DESTINATION"; then
    if [ -n "$BACKUP" ]; then mv "$BACKUP/Mac Polish.app" "$DESTINATION"; fi
    echo "Installation failed; previous app restored if present." >&2
    exit 1
fi
# Refresh this bundle's registration so Finder and pinned Dock items can pick up its icon.
REGISTRATION_TOOL="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$REGISTRATION_TOOL" ]; then
    "$REGISTRATION_TOOL" -f "$DESTINATION" >/dev/null 2>&1 || true
fi
echo "Installed: $DESTINATION"
if [ -n "$BACKUP" ]; then echo "Previous version kept at: $BACKUP/Mac Polish.app"; fi
echo "Open it from Finder in your Applications folder."
echo "This personal release is ad-hoc signed, not Apple-notarized. macOS may ask you to approve it in Privacy & Security."
echo "No security settings were changed. The application has not been launched."
