#!/bin/zsh

set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
OUTPUT_DIR="${MACPOLISH_OUTPUT_DIR:-$PROJECT_ROOT/dist}"
APP_BUNDLE="$OUTPUT_DIR/Mac Polish.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

cd "$PROJECT_ROOT"
source "$PROJECT_ROOT/Scripts/sdk.sh"
swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

mkdir -p "$MACOS_DIR" "$CONTENTS_DIR/Resources"
cp "$BIN_DIR/MacPolish" "$MACOS_DIR/MacPolish"
cp "$PROJECT_ROOT/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$PROJECT_ROOT/Resources/AppIcon.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"

ICON_FILE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$CONTENTS_DIR/Info.plist")"
[[ -s "$CONTENTS_DIR/Resources/$ICON_FILE" ]] || { print -u2 "Application icon resource is missing: $ICON_FILE"; exit 1; }

# Hardened runtime and a stable identity when available (see Scripts/sign-app.sh).
"$PROJECT_ROOT/Scripts/sign-app.sh" "$APP_BUNDLE"

print "Built: $APP_BUNDLE"
