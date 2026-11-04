#!/bin/zsh
# Signs a bundle with the hardened runtime and, when available, a stable identity.
# macOS keeps privacy permissions (Full Disk Access, Desktop, Documents, Downloads) for the app's designated
# requirement. A certificate gives every build the same requirement; an ad-hoc signature names one build only,
# so every update would start without permissions.
#
# Usage: Scripts/sign-app.sh <bundle>
#   MACPOLISH_SIGN_IDENTITY  identity name, or "-" for ad hoc. Default: MACPOLISH_DEFAULT_IDENTITY
#                            ("Mac Polish Local Signing", see create-signing-identity.sh) when present,
#                            otherwise ad hoc with a warning.
#   MACPOLISH_SIGN_KEYCHAIN  keychain that holds the identity (default: the keychain search list).
set -euo pipefail
BUNDLE="${1:?Usage: sign-app.sh <bundle>}"
ROOT="${0:A:h:h}"
DEFAULT_IDENTITY="${MACPOLISH_DEFAULT_IDENTITY:-Mac Polish Local Signing}"
typeset -a KEYCHAIN_LIST KEYCHAIN_OPTION ENTITLEMENTS_OPTION
# One persistent local identity, stored outside the checkout, is reused by every worktree.
# Its unlock password is kept in the login Keychain, never in this repository.
LOCAL_KEYCHAIN="$HOME/Library/Application Support/MacPolish Signing/signing.keychain-db"
if [[ -z "${MACPOLISH_SIGN_KEYCHAIN:-}" && -z "${MACPOLISH_SIGN_IDENTITY:-}" && -f "$LOCAL_KEYCHAIN" ]]; then
  LOCAL_PASSWORD="$(security find-generic-password -a "$USER" -s com.asaied.macpolish.signing-keychain -w)"
  security unlock-keychain -p "$LOCAL_PASSWORD" "$LOCAL_KEYCHAIN"
  unset LOCAL_PASSWORD
  MACPOLISH_SIGN_KEYCHAIN="$LOCAL_KEYCHAIN"
fi
if [[ -n "${MACPOLISH_SIGN_KEYCHAIN:-}" ]]; then
  KEYCHAIN_LIST=("$MACPOLISH_SIGN_KEYCHAIN")
  KEYCHAIN_OPTION=(--keychain "$MACPOLISH_SIGN_KEYCHAIN")
fi

IDENTITY="${MACPOLISH_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  if security find-identity -p codesigning "${KEYCHAIN_LIST[@]}" 2>/dev/null | grep -qF "\"$DEFAULT_IDENTITY\""; then
    IDENTITY="$DEFAULT_IDENTITY"
  else
    IDENTITY="-"
    print -u2 "WARNING: no signing identity \"$DEFAULT_IDENTITY\"; signing ad hoc. macOS will ask for every"
    print -u2 "permission again after each update. Create the identity once with Scripts/create-signing-identity.sh."
  fi
fi
ENTITLEMENTS="$ROOT/Resources/MacPolish.entitlements"
[[ -f "$ENTITLEMENTS" ]] && ENTITLEMENTS_OPTION=(--entitlements "$ENTITLEMENTS")

# The hardened runtime makes macOS ignore DYLD_* library injection, so no other program can run code
# inside Mac Polish and borrow its Full Disk Access.
codesign --force --options runtime "${ENTITLEMENTS_OPTION[@]}" "${KEYCHAIN_OPTION[@]}" --sign "$IDENTITY" "$BUNDLE"
codesign --verify --strict "$BUNDLE"
print "Signed $BUNDLE: $(codesign -d -r- "$BUNDLE" 2>&1 | sed -n 's/^#* *designated => //p')"
