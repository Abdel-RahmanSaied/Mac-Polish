#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
APP="$PWD/.build/UIE2E.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
typeset -a SOURCES
for source in Sources/MacPolish/*.swift; do
  case "$source" in
    */MacPolishApp.swift|*/main.swift) ;;
    *) SOURCES+=("$source") ;;
  esac
done
swiftc -parse-as-library "${SOURCES[@]}" Tests/UIE2EApp.swift -o "$APP/Contents/MacOS/UIE2E"
/usr/bin/ditto Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.asaied.macpolish.e2e' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable UIE2E' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Mac Polish E2E' "$APP/Contents/Info.plist"
/usr/bin/ditto Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
print "Built isolated UI fixture app: $APP"
