#!/bin/bash
set -euo pipefail

# Pinned release: review this script before running it.
VERSION="0.10.0"
REPOSITORY="Abdel-RahmanSaied/Mac-Polish"
ASSET="Mac-Polish-${VERSION}-macos-arm64.zip"
BASE_URL="https://github.com/${REPOSITORY}/releases/download/v${VERSION}"
USAGE="Usage: bash install.sh [--verify-only] [--from DIRECTORY]"
VERIFY_ONLY=false
SOURCE_DIRECTORY=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --verify-only) VERIFY_ONLY=true; shift ;;
        # Release files already on this Mac (for example dist/ from Scripts/package-release.sh). Same checks as a download.
        --from) [ "$#" -ge 2 ] || { echo "$USAGE" >&2; exit 1; }; SOURCE_DIRECTORY="$2"; shift 2 ;;
        *) echo "$USAGE" >&2; exit 1 ;;
    esac
done

[ "$(uname -s)" = "Darwin" ] || { echo "Mac Polish requires macOS." >&2; exit 1; }
[ "$(uname -m)" = "arm64" ] || { echo "This release requires native Apple Silicon (arm64). Intel and Rosetta terminals are not supported." >&2; exit 1; }
OS_VERSION="$(sw_vers -productVersion)"
[ "${OS_VERSION%%.*}" -ge 14 ] || { echo "macOS 14 or later is required." >&2; exit 1; }

INSTALL_DIRECTORY="$HOME/Applications"
DESTINATION="$INSTALL_DIRECTORY/Mac Polish.app"
# One archive of the version this install replaces. An archive is not an app: Launchpad, Spotlight and
# Launch Services list every app bundle, and macOS keeps one permission entry for all copies with this
# bundle identifier, so a second launchable copy could take Full Disk Access away from this one.
PREVIOUS_DIRECTORY="$HOME/Library/Application Support/Mac Polish/Previous Version"
REGISTRATION_TOOL="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
unregister() { if [ -x "$REGISTRATION_TOOL" ]; then "$REGISTRATION_TOOL" -u "$1" >/dev/null 2>&1 || true; fi; }
# Only the copy this install replaces matters; a copy running from elsewhere does not block it.
EXECUTABLE_PATTERN="$(printf '%s' "$DESTINATION/Contents/MacOS/MacPolish" | sed 's/[][\.*^$+?(){}|]/\\&/g')"
installed_copy_running() { pgrep -f "^${EXECUTABLE_PATTERN}( |$)" >/dev/null; }

if [ "$VERIFY_ONLY" = false ] && installed_copy_running; then
    echo "Quit Mac Polish before installing or updating." >&2
    exit 1
fi

STAGING="$(mktemp -d -t mac-polish-install)"
# macOS's bash 3.2 exits with status 0 after an unexpected error (such as an unset variable) when an EXIT trap
# exists, so an install that did not reach the end must never report success.
FINISHED=false
trap 'status=$?; rm -rf -- "$STAGING"; if [ "$status" -eq 0 ] && [ "$FINISHED" != true ]; then exit 70; fi; exit "$status"' EXIT
if [ -n "$SOURCE_DIRECTORY" ]; then
    echo "Using Mac Polish ${VERSION} from ${SOURCE_DIRECTORY}…"
    cp "$SOURCE_DIRECTORY/$ASSET" "$STAGING/$ASSET"
    cp "$SOURCE_DIRECTORY/SHA256SUMS.txt" "$STAGING/SHA256SUMS.txt"
else
    echo "Downloading Mac Polish ${VERSION}…"
    curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 "$BASE_URL/$ASSET" -o "$STAGING/$ASSET"
    curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 "$BASE_URL/SHA256SUMS.txt" -o "$STAGING/SHA256SUMS.txt"
fi
EXPECTED="$(awk -v asset="$ASSET" '$2 == asset { print $1 }' "$STAGING/SHA256SUMS.txt")"
[[ "$EXPECTED" =~ ^[0-9a-f]{64}$ ]] || { echo "Missing or invalid checksum." >&2; exit 1; }
ACTUAL="$(shasum -a 256 "$STAGING/$ASSET" | awk '{print $1}')"
[ "$EXPECTED" = "$ACTUAL" ] || { echo "Checksum verification failed." >&2; exit 1; }
ditto -x -k "$STAGING/$ASSET" "$STAGING/unpacked"
APP="$STAGING/unpacked/Mac Polish.app"
codesign --verify --deep --strict "$APP"
# The hardened runtime stops other programs from injecting code that would run with Mac Polish's Full Disk Access.
SIGNATURE="$(codesign -dv "$APP" 2>&1)"
case "$SIGNATURE" in
    *flags=*runtime*) ;;
    *) echo "The application is not signed with the hardened runtime." >&2; exit 1 ;;
esac
IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[ "$IDENTIFIER" = "com.asaied.macpolish" ] && [ "$BUNDLE_VERSION" = "$VERSION" ] || { echo "Unexpected application identity or version." >&2; exit 1; }
lipo "$APP/Contents/MacOS/MacPolish" -verify_arch arm64
echo "Download, checksum, application signature, hardened runtime and architecture verified."
if [ "$VERIFY_ONLY" = true ]; then FINISHED=true; exit 0; fi

if installed_copy_running; then
    echo "Mac Polish started during download. Quit it before installing." >&2
    exit 1
fi
mkdir -p "$INSTALL_DIRECTORY"
SIGNED_DIFFERENTLY=false
PREVIOUS_ARCHIVE=""
if [ -e "$DESTINATION" ] || [ -L "$DESTINATION" ]; then
    [ ! -L "$DESTINATION" ] || { echo "Refusing to replace a symbolic link." >&2; exit 1; }
    EXISTING_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DESTINATION/Contents/Info.plist" 2>/dev/null || true)"
    [ "$EXISTING_ID" = "com.asaied.macpolish" ] || { echo "An unrelated app already exists at $DESTINATION." >&2; exit 1; }
    # macOS keeps permissions for the installed app's signing requirement; tell the user if this version does not meet it.
    PREVIOUS_REQUIREMENT="$(codesign -d -r- "$DESTINATION" 2>&1 | sed -n 's/^#* *designated => //p' || true)"
    if [ -n "$PREVIOUS_REQUIREMENT" ] && ! codesign --verify -R="$PREVIOUS_REQUIREMENT" "$APP" >/dev/null 2>&1; then
        SIGNED_DIFFERENTLY=true
    fi
    PREVIOUS_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DESTINATION/Contents/Info.plist" 2>/dev/null || echo unknown)"
    PREVIOUS_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$DESTINATION/Contents/Info.plist" 2>/dev/null || echo 0)"
    PREVIOUS_ARCHIVE="Mac-Polish-${PREVIOUS_VERSION}-${PREVIOUS_BUILD}.zip"
    # Archived before anything moves: if this fails, the installed copy is untouched.
    ditto -c -k --sequesterRsrc --keepParent "$DESTINATION" "$STAGING/$PREVIOUS_ARCHIVE"
    mkdir -p "$STAGING/previous"
    mv "$DESTINATION" "$STAGING/previous/Mac Polish.app"
fi
if ! mv "$APP" "$DESTINATION"; then
    if [ -n "$PREVIOUS_ARCHIVE" ]; then mv "$STAGING/previous/Mac Polish.app" "$DESTINATION"; fi
    echo "Installation failed; previous app restored if present." >&2
    exit 1
fi
if [ -n "$PREVIOUS_ARCHIVE" ]; then
    unregister "$STAGING/previous/Mac Polish.app"
    mkdir -p "$PREVIOUS_DIRECTORY"
    rm -f "$PREVIOUS_DIRECTORY"/*.zip
    mv "$STAGING/$PREVIOUS_ARCHIVE" "$PREVIOUS_DIRECTORY/$PREVIOUS_ARCHIVE"
fi

# Earlier installers kept every previous version as an app inside Applications. Each one showed in Launchpad
# and Spotlight and could take over Mac Polish's single permission entry. Move only those folders to the Trash:
# named MacPolish-backup.*, holding nothing but a Mac Polish.app with this bundle identifier.
for LEGACY in "$INSTALL_DIRECTORY"/MacPolish-backup.*; do
    [ -d "$LEGACY" ] && [ ! -L "$LEGACY" ] || continue
    [ "$(ls -A "$LEGACY")" = "Mac Polish.app" ] || continue
    LEGACY_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$LEGACY/Mac Polish.app/Contents/Info.plist" 2>/dev/null || true)"
    [ "$LEGACY_ID" = "com.asaied.macpolish" ] || continue
    unregister "$LEGACY/Mac Polish.app"
    mkdir -p "$HOME/.Trash"
    TRASHED="$HOME/.Trash/$(basename "$LEGACY")-$(date +%Y%m%d%H%M%S)"
    if mv "$LEGACY" "$TRASHED"; then echo "Moved an old backup copy to the Trash: $LEGACY"; fi
done

# Refresh this bundle's registration so Finder and pinned Dock items can pick up its icon.
if [ -x "$REGISTRATION_TOOL" ]; then
    "$REGISTRATION_TOOL" -f "$DESTINATION" >/dev/null 2>&1 || true
fi
echo "Installed: $DESTINATION"
if [ -n "$PREVIOUS_ARCHIVE" ]; then
    echo "Previous version saved as: $PREVIOUS_DIRECTORY/$PREVIOUS_ARCHIVE"
    echo "To go back, quit Mac Polish and unzip it into $INSTALL_DIRECTORY, replacing the installed copy."
fi
echo "Open it from Finder in your Applications folder."
if [ "$SIGNED_DIFFERENTLY" = true ]; then
    echo "This version is signed differently from the one it replaced, so macOS asks again for Full Disk Access and folder access."
    echo "In System Settings → Privacy & Security → Full Disk Access, remove the old Mac Polish entry with −, then add this copy with +."
fi
echo "This personal release is not Apple-notarized. macOS may ask you to approve it in Privacy & Security."
echo "No security settings were changed. The application has not been launched."
FINISHED=true
