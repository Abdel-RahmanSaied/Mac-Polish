#!/bin/zsh
# Runs the real installer against fixture releases in a throwaway home folder.
# Every app bundle inside Applications shows in Launchpad and Spotlight, and macOS keeps one permission entry
# for all copies with Mac Polish's bundle identifier, so the installer must leave exactly one copy there.
set -euo pipefail
ROOT="${0:A:h:h}"
WORK="$(mktemp -d -t macpolish-installer)"
WORK="${WORK:A}"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
TEST_HOME="$WORK/home"
APPLICATIONS="$TEST_HOME/Applications"
PREVIOUS="$TEST_HOME/Library/Application Support/Mac Polish/Previous Version"
VERSION="$(awk -F '"' '$1 == "VERSION=" {print $2}' "$ROOT/Scripts/install.sh")"
cleanup() {
  # Fixture bundles must not stay in this Mac's Launch Services database.
  find "$WORK" -name '*.app' -prune -exec "$LSREGISTER" -u {} \; 2>/dev/null || true
  "$LSREGISTER" -u "$APPLICATIONS/Mac Polish.app" 2>/dev/null || true
  rm -rf -- "$WORK"
}
trap cleanup EXIT
fail() { print -u2 "FAIL: $*"; exit 1 }
ok() { print "  ok: $*" }
# The dump is written out first: with pipefail, `grep -q` closing the pipe early would fail the check by itself.
registered() { "$LSREGISTER" -dump > "$WORK/launch-services.txt" 2>/dev/null; grep -qF -- "$1" "$WORK/launch-services.txt" }

print "Building fixture releases"
mkdir -p "$WORK/bin"
print 'int main(void) { return 0; }' > "$WORK/bin/main.c"
clang -arch arm64 "$WORK/bin/main.c" -o "$WORK/bin/MacPolish"
# fixture <bundle> <version> <build>
fixture() {
  mkdir -p "$1/Contents/MacOS"
  cp "$WORK/bin/MacPolish" "$1/Contents/MacOS/MacPolish"
  cp "$ROOT/Resources/Info.plist" "$1/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $2" -c "Set :CFBundleVersion $3" "$1/Contents/Info.plist"
  codesign --force --options runtime --sign - "$1" >/dev/null 2>&1
}
release() { # release <directory> <build>
  mkdir -p "$1"
  fixture "$1/stage/Mac Polish.app" "$VERSION" "$2"
  ditto -c -k --sequesterRsrc --keepParent "$1/stage/Mac Polish.app" "$1/Mac-Polish-$VERSION-macos-arm64.zip"
  rm -rf "$1/stage"
  (cd "$1" && shasum -a 256 "Mac-Polish-$VERSION-macos-arm64.zip" > SHA256SUMS.txt)
}
release "$WORK/release" 900
release "$WORK/release-2" 901

print "Preparing a home folder like one left by earlier installers"
fixture "$APPLICATIONS/Mac Polish.app" 0.9.0 13
fixture "$APPLICATIONS/MacPolish-backup.AbC123/Mac Polish.app" 0.8.0 12
mkdir -p "$APPLICATIONS/MacPolish-backup.notours" && print "user file" > "$APPLICATIONS/MacPolish-backup.notours/notes.txt"
mkdir -p "$APPLICATIONS/MacPolish-backup.other/Other.app/Contents"
"$LSREGISTER" -f "$APPLICATIONS/MacPolish-backup.AbC123/Mac Polish.app"
registered "$APPLICATIONS/MacPolish-backup.AbC123" || fail "fixture: the old backup copy should start registered"

print "A tampered release changes nothing"
mkdir -p "$WORK/tampered" && cp "$WORK/release/"* "$WORK/tampered/"
print "0000000000000000000000000000000000000000000000000000000000000000  Mac-Polish-$VERSION-macos-arm64.zip" > "$WORK/tampered/SHA256SUMS.txt"
if HOME="$TEST_HOME" bash "$ROOT/Scripts/install.sh" --from "$WORK/tampered" >/dev/null 2>&1; then
  fail "a release with a wrong checksum must be refused"
fi
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APPLICATIONS/Mac Polish.app/Contents/Info.plist")" == 0.9.0 ]] \
  || fail "a refused release must leave the installed version in place"
[[ -d "$APPLICATIONS/MacPolish-backup.AbC123" ]] || fail "a refused release must not move anything"
ok "a wrong checksum is refused before anything moves"

if HOME="$TEST_HOME" bash "$ROOT/Scripts/install.sh" --from "$WORK/missing" >/dev/null 2>&1; then
  fail "a missing release folder must be refused"
fi
[[ -d "$APPLICATIONS/MacPolish-backup.AbC123" ]] || fail "a refused install must not move anything"
ok "a missing release folder is refused before anything moves"

print "Installing over the old version"
OUTPUT="$(HOME="$TEST_HOME" bash "$ROOT/Scripts/install.sh" --from "$WORK/release" 2>&1)" || fail "install failed: $OUTPUT"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APPLICATIONS/Mac Polish.app/Contents/Info.plist")" == "$VERSION" ]] \
  || fail "the new version is not installed"
# Break caught: backups left as app bundles inside Applications (one more Mac Polish in Launchpad per update).
APP_BUNDLES=("${(@f)$(find "$APPLICATIONS" -name '*.app' -prune -print | sort)}")
[[ "${APP_BUNDLES[*]}" == "$APPLICATIONS/Mac Polish.app $APPLICATIONS/MacPolish-backup.other/Other.app" ]] \
  || fail "Applications must hold one Mac Polish copy, got: ${APP_BUNDLES[*]}"
ok "one Mac Polish copy in Applications"
[[ ! -e "$APPLICATIONS/MacPolish-backup.AbC123" ]] || fail "the old backup copy is still in Applications"
TRASHED=("$TEST_HOME"/.Trash/MacPolish-backup.AbC123*(N))
(( ${#TRASHED} == 1 )) && [[ -d "${TRASHED[1]}/Mac Polish.app" ]] || fail "the old backup copy must be in the Trash"
[[ -f "$APPLICATIONS/MacPolish-backup.notours/notes.txt" && -d "$APPLICATIONS/MacPolish-backup.other/Other.app" ]] \
  || fail "folders that are not an earlier installer's backup must be left alone"
[[ "$OUTPUT" == *"Moved an old backup copy to the Trash"* ]] || fail "the user is told about the moved backup"
ok "the earlier installer's backup is in the Trash; unrelated folders are untouched"
! registered "$APPLICATIONS/MacPolish-backup.AbC123" || fail "the old backup copy is still registered with Launch Services"
ok "the old backup copy is unregistered from Launch Services"

ARCHIVES=("$PREVIOUS"/*.zip(N))
(( ${#ARCHIVES} == 1 )) || fail "one archive of the previous version, got ${#ARCHIVES}"
[[ "${ARCHIVES[1]:t}" == "Mac-Polish-0.9.0-13.zip" ]] || fail "the archive names the previous version: ${ARCHIVES[1]:t}"
[[ -z "$(find "$TEST_HOME/Library" -name '*.app' -print)" ]] || fail "no app bundle may be stored outside Applications"
mkdir -p "$WORK/restore" && ditto -x -k "${ARCHIVES[1]}" "$WORK/restore"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$WORK/restore/Mac Polish.app/Contents/Info.plist")" == 0.9.0 ]] \
  || fail "the archive restores the previous version"
codesign --verify --strict "$WORK/restore/Mac Polish.app" || fail "the restored copy keeps a valid signature"
[[ "$OUTPUT" == *"Previous version saved as"* ]] || fail "the user is told where the previous version is"
ok "the previous version is one zip archive (not a launchable copy) that restores with a valid signature"
[[ "$OUTPUT" == *"signed differently"* ]] || fail "an ad-hoc to ad-hoc update is signed differently and must say so"
ok "the user is told that this update is signed differently"

print "Installing again keeps a single archive"
OUTPUT="$(HOME="$TEST_HOME" bash "$ROOT/Scripts/install.sh" --from "$WORK/release-2" 2>&1)" || fail "second install failed: $OUTPUT"
ARCHIVES=("$PREVIOUS"/*.zip(N))
(( ${#ARCHIVES} == 1 )) && [[ "${ARCHIVES[1]:t}" == "Mac-Polish-$VERSION-900.zip" ]] || fail "only the latest previous version is kept, got ${ARCHIVES[*]:t}"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APPLICATIONS/Mac Polish.app/Contents/Info.plist")" == 901 ]] || fail "second update not installed"
ok "a second update replaces the archive instead of adding copies"

print "PASS: installer leaves one copy in Applications, archives the previous version, trashes old backup copies, refuses tampered releases"
