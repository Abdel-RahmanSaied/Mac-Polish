#!/bin/zsh
# Signing checks on real signed bundles built from the app's sources:
#  - a stable identity keeps the designated requirement across builds, so macOS keeps permissions after updates;
#  - an ad-hoc signature does not (control: proves the check can fail);
#  - the hardened runtime ignores injected libraries (control: an unhardened copy loads them);
#  - release verification refuses unhardened or build-only signatures;
#  - quitting another app (Memory → Quit) still works under the hardened runtime.
# Uses a temporary keychain; the login keychain is never touched.
set -euo pipefail
ROOT="${0:A:h:h}"
WORK="$(mktemp -d -t macpolish-signing)"
KEYCHAIN="$WORK/signing-test.keychain-db"
CI_KEYCHAIN="$WORK/ci-import.keychain-db"
BACKUP_PASSWORD="macpolish-backup-test"
KEYCHAIN_PASSWORD="macpolish-signing-test"
IDENTITY="Mac Polish Test Signing"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
cleanup() {
  pkill -f "$WORK/QuitTarget.app/Contents/MacOS/QuitTarget" 2>/dev/null || true
  # Helper apps opened with `open` are registered with Launch Services; remove them with the fixtures.
  find "$WORK" -name '*.app' -prune -exec "$LSREGISTER" -u {} \; 2>/dev/null || true
  security delete-keychain "$KEYCHAIN" 2>/dev/null || true
  security delete-keychain "$CI_KEYCHAIN" 2>/dev/null || true
  rm -rf -- "$WORK"
}
trap cleanup EXIT
fail() { print -u2 "FAIL: $*"; exit 1 }
ok() { print "  ok: $*" }
requirement() { codesign -d -r- "$1" 2>&1 | sed -n 's/^#* *designated => //p' }
cdhash() { codesign -dv --verbose=4 "$1" 2>&1 | sed -n 's/^CDHash=//p' }
# Captured first: with pipefail, `grep -q` closing the pipe early would fail the check by itself.
hardened() { local signature; signature="$(codesign -dv "$1" 2>&1)"; [[ "$signature" == *"flags="*runtime* ]] }

print "Preparing a temporary signing identity"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
MACPOLISH_KEYCHAIN_PASSWORD="$KEYCHAIN_PASSWORD" MACPOLISH_EXPORT_PASSWORD="$BACKUP_PASSWORD" \
  "$ROOT/Scripts/create-signing-identity.sh" --keychain "$KEYCHAIN" --name "$IDENTITY" --export "$WORK/backup.p12" >/dev/null
[[ -s "$WORK/backup.p12" ]] || fail "the encrypted backup was not written"
[[ "$(stat -f '%Lp' "$WORK/backup.p12")" == 600 ]] || fail "the backup must be readable by its owner only"
security find-identity -p codesigning "$KEYCHAIN" | grep -q "\"$IDENTITY\"" || fail "identity was not created"
if MACPOLISH_KEYCHAIN_PASSWORD="$KEYCHAIN_PASSWORD" "$ROOT/Scripts/create-signing-identity.sh" --keychain "$KEYCHAIN" --name "$IDENTITY" >/dev/null 2>&1; then
  fail "creating the same identity twice must refuse: a second certificate would change the requirement"
fi
ok "identity created once, refused the second time"
export MACPOLISH_SIGN_KEYCHAIN="$KEYCHAIN"

print "Building the app's sources (scan worker included)"
typeset -a SOURCES
for source in "$ROOT"/Sources/MacPolish/*.swift; do
  case "$source" in
    */MacPolishApp.swift|*/main.swift|*/ContentView.swift|*/AdvancedViews.swift) ;;
    *) SOURCES+=("$source") ;;
  esac
done
cat > "$WORK/fixture-main.swift" <<'EOF'
import Foundation
@main enum SigningFixture {
    static func main() {
        if let status = ScanWorker.runIfRequested(CommandLine.arguments) { exit(status) }
        print(SigningIdentity.currentRequirement() ?? "no requirement")
    }
}
EOF
swiftc -parse-as-library "${SOURCES[@]}" "$WORK/fixture-main.swift" -o "$WORK/MacPolish" 2>/dev/null
make_bundle() {
  mkdir -p "$1/Contents/MacOS" "$1/Contents/Resources"
  cp "$WORK/MacPolish" "$1/Contents/MacOS/MacPolish"
  cp "$ROOT/Resources/Info.plist" "$1/Contents/Info.plist"
  cp "$ROOT/Resources/AppIcon.icns" "$1/Contents/Resources/AppIcon.icns"
}
sign() { MACPOLISH_SIGN_IDENTITY="$1" "$ROOT/Scripts/sign-app.sh" "$2" >/dev/null }

print "Point 1: permissions survive an update signed with the same identity"
STABLE="$WORK/stable/Mac Polish.app"; make_bundle "$STABLE"; sign "$IDENTITY" "$STABLE"
STABLE_REQUIREMENT="$(requirement "$STABLE")"
[[ "$STABLE_REQUIREMENT" == *"certificate leaf"* && "$STABLE_REQUIREMENT" != cdhash* ]] \
  || fail "the requirement still names one build: $STABLE_REQUIREMENT"
NEXT="$WORK/next/Mac Polish.app"; make_bundle "$NEXT"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 9999' "$NEXT/Contents/Info.plist"
sign "$IDENTITY" "$NEXT"
[[ "$(cdhash "$STABLE")" != "$(cdhash "$NEXT")" ]] || fail "the next build must differ from the first"
# macOS compares the stored requirement with the new code exactly like this before honouring a permission.
codesign --verify -R="$STABLE_REQUIREMENT" "$NEXT" 2>/dev/null || fail "the next build does not satisfy the stored requirement"
ok "a different build satisfies the earlier requirement: $STABLE_REQUIREMENT"
# The release workflow imports the backup into a temporary keychain; its builds must meet the same requirement.
CI_NAME="$(MACPOLISH_SIGNING_P12_PASSWORD="$BACKUP_PASSWORD" "$ROOT/Scripts/import-signing-identity.sh" "$WORK/backup.p12" "$CI_KEYCHAIN")"
[[ "$CI_NAME" == "$IDENTITY" ]] || fail "the imported identity is named \"$CI_NAME\""
CI_BUILD="$WORK/ci/Mac Polish.app"; make_bundle "$CI_BUILD"
MACPOLISH_SIGN_KEYCHAIN="$CI_KEYCHAIN" MACPOLISH_SIGN_IDENTITY="$CI_NAME" "$ROOT/Scripts/sign-app.sh" "$CI_BUILD" >/dev/null
[[ "$(requirement "$CI_BUILD")" == "$STABLE_REQUIREMENT" ]] || fail "a CI build has another requirement: $(requirement "$CI_BUILD")"
ok "a build signed from the imported backup (as in CI) has the same requirement as a local build"
OWN="$("$STABLE/Contents/MacOS/MacPolish")"
[[ "$OWN" != cdhash* && "$OWN" == *"certificate leaf"* ]] || fail "the app reads its own requirement as build-only: $OWN"
ok "the app sees a stable requirement (setup shows no reset warning)"

ADHOC="$WORK/adhoc/Mac Polish.app"; make_bundle "$ADHOC"; sign - "$ADHOC"
ADHOC_REQUIREMENT="$(requirement "$ADHOC")"
[[ "$ADHOC_REQUIREMENT" == cdhash* ]] || fail "ad-hoc control should be build-only: $ADHOC_REQUIREMENT"
ADHOC_NEXT="$WORK/adhoc-next/Mac Polish.app"; make_bundle "$ADHOC_NEXT"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 9999' "$ADHOC_NEXT/Contents/Info.plist"
sign - "$ADHOC_NEXT"
if codesign --verify -R="$ADHOC_REQUIREMENT" "$ADHOC_NEXT" 2>/dev/null; then
  fail "control: an ad-hoc update must not satisfy the previous ad-hoc requirement"
fi
[[ "$("$ADHOC/Contents/MacOS/MacPolish")" == cdhash* ]] || fail "the app must detect its ad-hoc signature"
ok "control: an ad-hoc update loses the requirement, and the app detects it"
DEFAULT_LOG="$WORK/default-sign.log"
MACPOLISH_SIGN_IDENTITY= MACPOLISH_DEFAULT_IDENTITY="Mac Polish Missing Identity" "$ROOT/Scripts/sign-app.sh" "$ADHOC" >/dev/null 2>"$DEFAULT_LOG"
grep -q "WARNING" "$DEFAULT_LOG" || fail "falling back to ad-hoc must warn"
ok "without an identity, signing falls back to ad-hoc with a warning"

print "Point 2: the hardened runtime ignores injected libraries"
for app in "$STABLE" "$ADHOC"; do
  hardened "$app" || fail "hardened runtime flag missing on $app"
done
cat > "$WORK/probe.c" <<'EOF'
#include <stdio.h>
__attribute__((constructor)) static void probe(void) { fprintf(stderr, "PROBE-LOADED\n"); }
EOF
clang -dynamiclib "$WORK/probe.c" -o "$WORK/probe.dylib"
UNHARDENED="$WORK/unhardened/Mac Polish.app"; make_bundle "$UNHARDENED"
codesign --force --sign - "$UNHARDENED" >/dev/null 2>&1
injected() { DYLD_INSERT_LIBRARIES="$WORK/probe.dylib" "$1/Contents/MacOS/MacPolish" --scan-worker basic 2>&1 || true }
[[ "$(injected "$UNHARDENED")" == *PROBE-LOADED* ]] || fail "control: the probe library must load into an unhardened copy"
for app in "$STABLE" "$ADHOC"; do
  INJECTION_OUTPUT="$(injected "$app")"
  if [[ "$INJECTION_OUTPUT" == *PROBE-LOADED* ]]; then
    SIP_STATUS="$(/usr/bin/csrutil status 2>&1 || true)"
    if [[ "$SIP_STATUS" == *"status: disabled"* && "${CI:-}" == true ]]; then
      print "::warning::Runtime injection prevention is not validated on this SIP-disabled CI host. Signature flags remain required; run this test on a SIP-enabled Mac before release."
    else
      print -u2 -- "$INJECTION_OUTPUT"
      fail "an injected library ran inside $app ($SIP_STATUS)"
    fi
  fi
done
ok "runtime injection test completed; SIP-disabled CI limits are reported above"

print "Release verification"
"$ROOT/Scripts/verify-release-signature.sh" "$STABLE" >/dev/null || fail "a stable, hardened signature must pass"
if "$ROOT/Scripts/verify-release-signature.sh" "$ADHOC" >/dev/null 2>&1; then fail "an ad-hoc release must be refused"; fi
MACPOLISH_ALLOW_ADHOC=1 "$ROOT/Scripts/verify-release-signature.sh" "$ADHOC" >/dev/null 2>&1 || fail "an explicit ad-hoc override must pass"
if MACPOLISH_ALLOW_ADHOC=1 "$ROOT/Scripts/verify-release-signature.sh" "$UNHARDENED" >/dev/null 2>&1; then
  fail "an unhardened release must be refused even with the ad-hoc override"
fi
ok "stable passes; ad-hoc needs an explicit override; unhardened is always refused"

print "Memory → Quit under the hardened runtime"
quit_bundle() { # name, bundle id, source file
  local app="$WORK/$1.app"
  mkdir -p "$app/Contents/MacOS"
  swiftc "$3" -o "$app/Contents/MacOS/$1" 2>/dev/null
  cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$2</string>
<key>CFBundleExecutable</key><string>$1</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
EOF
}
cat > "$WORK/target.swift" <<'EOF'
import AppKit
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
EOF
cat > "$WORK/sender.swift" <<'EOF'
import AppKit
// Mirrors MemoryMonitor.requestQuit: a normal quit request through NSRunningApplication.
let output = URL(fileURLWithPath: CommandLine.arguments[1])
func finish(_ text: String) -> Never { try? text.write(to: output, atomically: true, encoding: .utf8); exit(0) }
let deadline = Date().addingTimeInterval(15)
var target: NSRunningApplication?
while target == nil && Date() < deadline {
    target = NSRunningApplication.runningApplications(withBundleIdentifier: "com.asaied.macpolish.test.quit-target").first
    if target == nil { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
}
guard let target else { finish("target-not-found") }
let sent = target.terminate()
while !target.isTerminated && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
finish(target.isTerminated ? "terminated" : (sent ? "sent-but-still-running" : "refused"))
EOF
quit_bundle QuitTarget com.asaied.macpolish.test.quit-target "$WORK/target.swift"
quit_bundle QuitSender com.asaied.macpolish.test.quit-sender "$WORK/sender.swift"
codesign --force --sign - "$WORK/QuitTarget.app" >/dev/null 2>&1
# Signed exactly like the app: same script, same hardened runtime and entitlements.
sign - "$WORK/QuitSender.app"
hardened "$WORK/QuitSender.app" || fail "the quit sender must be hardened"
open -g -j "$WORK/QuitTarget.app"
for _ in {1..100}; do pgrep -f "$WORK/QuitTarget.app/Contents/MacOS/QuitTarget" >/dev/null && break; sleep 0.1; done
pgrep -f "$WORK/QuitTarget.app/Contents/MacOS/QuitTarget" >/dev/null || fail "the quit target did not start"
open -g -j -W "$WORK/QuitSender.app" --args "$WORK/quit-result"
QUIT_RESULT="$(cat "$WORK/quit-result" 2>/dev/null || print missing)"
[[ "$QUIT_RESULT" == terminated ]] || fail "a hardened app could not quit another app: $QUIT_RESULT"
ok "a hardened app still quits another app normally"

print "PASS: stable signing requirements, hardened signature checks, release gates and Quit; see host-specific injection results above"
