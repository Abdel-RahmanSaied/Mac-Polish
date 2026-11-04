#!/bin/zsh
# Refuses a release whose signature would expose users or reset their permissions.
# Usage: Scripts/verify-release-signature.sh <app>
#   MACPOLISH_ALLOW_ADHOC=1 accepts an ad-hoc (build-only) signature. The hardened runtime is always required.
set -euo pipefail
APP="${1:?Usage: verify-release-signature.sh <app>}"
codesign --verify --deep --strict "$APP"
# Captured first: with pipefail, `grep -q` closing the pipe early would fail the check by itself.
SIGNATURE="$(codesign -dv "$APP" 2>&1)"
if [[ "$SIGNATURE" != *"flags="*runtime* ]]; then
  print -u2 "Refusing: $APP is not signed with the hardened runtime. Other programs could inject code into it"
  print -u2 "and use its Full Disk Access. Sign it with Scripts/sign-app.sh."
  exit 1
fi
REQUIREMENT="$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^#* *designated => //p')"
if [[ "$REQUIREMENT" == cdhash* && "${MACPOLISH_ALLOW_ADHOC:-}" != 1 ]]; then
  print -u2 "Refusing: $APP is signed ad hoc ($REQUIREMENT). After this update macOS would ask every user"
  print -u2 "for Full Disk Access and folder access again. Create a stable identity once with"
  print -u2 "Scripts/create-signing-identity.sh, or set MACPOLISH_ALLOW_ADHOC=1 to release anyway."
  exit 1
fi
print "Release signature: $REQUIREMENT"
