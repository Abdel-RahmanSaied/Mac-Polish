#!/bin/zsh
set -euo pipefail
PROJECT_ROOT="${0:A:h:h}"
cd "$PROJECT_ROOT"
[[ "$(uname -m)" == "arm64" ]] || { print -u2 "Build this release on Apple Silicon."; exit 1; }
./Scripts/build-app.sh
APP="$PROJECT_ROOT/dist/Mac Polish.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ARCHIVE="Mac-Polish-${VERSION}-macos-arm64.zip"
codesign --verify --deep --strict "$APP"
lipo "$APP/Contents/MacOS/MacPolish" -verify_arch arm64
ditto -c -k --sequesterRsrc --keepParent "$APP" "$PROJECT_ROOT/dist/$ARCHIVE"
cp Scripts/install.sh dist/install.sh
cd dist
shasum -a 256 "$ARCHIVE" install.sh > SHA256SUMS.txt
print "Release assets ready in $PROJECT_ROOT/dist"
