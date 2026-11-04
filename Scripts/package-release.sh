#!/bin/zsh
set -euo pipefail
PROJECT_ROOT="${0:A:h:h}"
cd "$PROJECT_ROOT"
./Scripts/build-app.sh
DIST="${MACPOLISH_OUTPUT_DIR:-$PROJECT_ROOT/dist}"
APP="$DIST/Mac Polish.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
INSTALLER_VERSION="$(awk -F '"' '$1 == "VERSION=" {print $2}' Scripts/install.sh)"
[[ "$INSTALLER_VERSION" == "$VERSION" ]] || { print -u2 "Installer version does not match app version."; exit 1; }
ARCHIVE="Mac-Polish-${VERSION}-macos-arm64.zip"
# Refuses an unhardened build, and an ad-hoc one unless MACPOLISH_ALLOW_ADHOC=1.
./Scripts/verify-release-signature.sh "$APP"
lipo "$APP/Contents/MacOS/MacPolish" -verify_arch arm64
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/$ARCHIVE"
cp Scripts/install.sh "$DIST/install.sh"
cd "$DIST"
shasum -a 256 "$ARCHIVE" install.sh > SHA256SUMS.txt
print "Release assets ready in $DIST"
