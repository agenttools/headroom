#!/usr/bin/env bash
# make-signing-cert.sh — create the "Headroom Local Signing" code-signing identity (SPEC §8.3).
#
# Run this ONCE. With a stable identity, the designated requirement of Headroom.app stays the
# same across rebuilds, so macOS keeps the Automation grants (Chrome, Ghostty) instead of asking again.
#
#   scripts/make-signing-cert.sh                       import into the login keychain
#   scripts/make-signing-cert.sh --keychain <path>     import into another keychain (for example a scratch one)
#   scripts/make-signing-cert.sh --force               add a new identity even if one with this name exists
#
# It is self-signed and only valid for code signing (EKU critical,codeSigning; keyUsage digitalSignature;
# 3650 days). The key never leaves the keychain: the temporary key and .p12 files are deleted at exit.
# It prints the SHA-1 to use as SIGN_ID (build.sh finds the identity by name, so this is optional).
set -euo pipefail

NAME="Headroom Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --keychain) KEYCHAIN="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

[[ -f "$KEYCHAIN" ]] || { echo "keychain not found: $KEYCHAIN" >&2; exit 1; }

# Existing identity? (Without -v: a self-signed cert is "not trusted" but codesign still uses it.)
if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "\"$NAME\""; then
  if [[ $FORCE == 0 ]]; then
    echo "\"$NAME\" already exists in $KEYCHAIN:"
    security find-identity -p codesigning "$KEYCHAIN" | grep "\"$NAME\""
    echo "Nothing to do. (Use --force to add another one; build.sh would then need SIGN_ID=<sha1>.)"
    exit 0
  fi
fi

# openssl 3 needs -legacy so that `security import` can read the .p12; LibreSSL (/usr/bin/openssl) does not.
OPENSSL=openssl
for c in /opt/homebrew/bin/openssl /usr/local/bin/openssl openssl; do
  if command -v "$c" >/dev/null 2>&1; then OPENSSL="$c"; break; fi
done
LEGACY=()
if "$OPENSSL" pkcs12 -help 2>&1 | grep -q -- '-legacy'; then LEGACY=(-legacy); fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
chmod 700 "$TMP"
cat >"$TMP/cs.cnf" <<EOF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
subjectKeyIdentifier=hash
EOF

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cs.cnf" \
  -keyout "$TMP/cs.key" -out "$TMP/cs.crt" 2>/dev/null
# A throwaway random passphrase protects the .p12 only for the moment between these two commands.
P12PASS="$("$OPENSSL" rand -hex 16)"
"$OPENSSL" pkcs12 -export ${LEGACY[@]+"${LEGACY[@]}"} -name "$NAME" -inkey "$TMP/cs.key" -in "$TMP/cs.crt" \
  -out "$TMP/cs.p12" -passout "pass:$P12PASS"

security import "$TMP/cs.p12" -k "$KEYCHAIN" -P "$P12PASS" -T /usr/bin/codesign >/dev/null

SHA1="$("$OPENSSL" x509 -in "$TMP/cs.crt" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')"
echo "Created \"$NAME\" in $KEYCHAIN"
echo "SHA-1: $SHA1"
echo
echo "build.sh finds it by name. If you ever have two, pin one with:  SIGN_ID=$SHA1 scripts/build.sh"
echo "The first signing may show a keychain prompt for codesign: choose \"Always Allow\"."
