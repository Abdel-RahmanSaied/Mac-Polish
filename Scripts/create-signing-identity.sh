#!/bin/zsh
# Creates a self-signed code signing identity, once, so every Mac Polish build has the same designated requirement.
# macOS keeps Full Disk Access and folder permissions for that requirement, so updates keep them.
# A Developer ID certificate does the same and also allows notarization; this is the free alternative.
#
# Usage: Scripts/create-signing-identity.sh [--name NAME] [--keychain PATH] [--export FILE.p12]
#   Default name "Mac Polish Local Signing" (what Scripts/sign-app.sh looks for); default keychain: login.
#   --export writes an encrypted backup (password: MACPOLISH_EXPORT_PASSWORD) for safekeeping and for the
#   release workflow's MACPOLISH_SIGNING_P12_BASE64 secret. Every build must use this one certificate.
#   MACPOLISH_KEYCHAIN_PASSWORD (optional) lets codesign use this key without asking. Otherwise macOS asks
#   once at the first build; choose Always Allow.
set -euo pipefail
NAME="Mac Polish Local Signing"
KEYCHAIN=""
EXPORT=""
while (( $# )); do
  case "$1" in
    --name) NAME="${2:?}"; shift 2 ;;
    --keychain) KEYCHAIN="${2:?}"; shift 2 ;;
    --export) EXPORT="${2:?}"; shift 2 ;;
    *) print -u2 "Usage: $0 [--name NAME] [--keychain PATH] [--export FILE.p12]"; exit 1 ;;
  esac
done
if [[ -n "$EXPORT" ]]; then
  [[ -n "${MACPOLISH_EXPORT_PASSWORD:-}" ]] || { print -u2 "--export needs MACPOLISH_EXPORT_PASSWORD to encrypt the backup."; exit 1; }
  [[ ! -e "$EXPORT" ]] || { print -u2 "Refusing to overwrite $EXPORT."; exit 1; }
fi
typeset -a KEYCHAIN_LIST IMPORT_TARGET
if [[ -n "$KEYCHAIN" ]]; then KEYCHAIN_LIST=("$KEYCHAIN"); IMPORT_TARGET=(-k "$KEYCHAIN"); fi

if security find-identity -p codesigning "${KEYCHAIN_LIST[@]}" 2>/dev/null | grep -qF "\"$NAME\""; then
  print -u2 "A signing identity named \"$NAME\" already exists; keep using it."
  print -u2 "A second certificate would change the designated requirement, and macOS would ask users for permissions again."
  exit 1
fi

WORK="$(mktemp -d -t macpolish-identity)"
trap 'rm -rf -- "$WORK"' EXIT
chmod 700 "$WORK"
cat > "$WORK/certificate.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
# The system LibreSSL writes a PKCS#12 file that every supported macOS imports.
/usr/bin/openssl req -x509 -newkey rsa:3072 -nodes -days 3650 -config "$WORK/certificate.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/certificate.pem" 2>/dev/null
TRANSFER_PASSWORD="$(/usr/bin/openssl rand -hex 16)"
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/certificate.pem" -name "$NAME" \
  -passout "pass:$TRANSFER_PASSWORD" -out "$WORK/identity.p12" 2>/dev/null
# codesign also needs the private-key keychain in the user search list on clean CI hosts.
if [[ -n "$KEYCHAIN" ]]; then
  typeset -a SEARCH_KEYCHAINS
  SEARCH_KEYCHAINS=("${(@f)$(security list-keychains -d user | sed 's/^ *"//; s/"$//')}")
  security list-keychains -d user -s "$KEYCHAIN" "${SEARCH_KEYCHAINS[@]}"
fi
security import "$WORK/identity.p12" "${IMPORT_TARGET[@]}" -P "$TRANSFER_PASSWORD" -T /usr/bin/codesign >/dev/null
if [[ -n "${MACPOLISH_KEYCHAIN_PASSWORD:-}" ]]; then
  # Only this identity's key (matched by label), never the keychain's other keys.
  security set-key-partition-list -S apple-tool:,apple: -s -l "$NAME" -k "$MACPOLISH_KEYCHAIN_PASSWORD" "${KEYCHAIN_LIST[@]}" >/dev/null
fi
if [[ -n "$EXPORT" ]]; then
  ( umask 077
    /usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/certificate.pem" -name "$NAME" \
      -passout "pass:$MACPOLISH_EXPORT_PASSWORD" -out "$EXPORT" 2>/dev/null )
  print "Encrypted backup written to $EXPORT. Store it and its password safely, then delete local copies you do not need."
fi
FINGERPRINT="$(/usr/bin/openssl x509 -noout -fingerprint -sha1 -in "$WORK/certificate.pem" | sed 's/.*=//; s/://g')"
print "Created signing identity \"$NAME\" (certificate SHA-1 $FINGERPRINT)."
print "Builds now use it: Scripts/build-app.sh signs with it automatically."
print "Back it up now: Keychain Access → My Certificates → \"$NAME\" → Export. If it is lost, the next"
print "update is signed differently and every user must allow Full Disk Access and folder access again."
