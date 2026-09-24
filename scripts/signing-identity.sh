#!/bin/bash
# One-time: create a self-signed code-signing identity "JevCUA Dev Signing" in a project keychain
# and add that keychain to the user's search list. scripts/bundle.sh signs with it when present,
# so TCC keys Microphone, Speech, and Accessibility to the certificate and rebuilds keep the
# grants (an ad-hoc signature changes with every build and resets them).
set -euo pipefail
NAME="JevCUA Dev Signing"
KEYCHAIN="$HOME/Library/Keychains/jevcua-signing.keychain-db"
PASS="jevcua-signing"     # protects only this keychain, which holds only this dev certificate
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "identity '$NAME' already present"; exit 0
fi

cat > "$WORK/ext.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $NAME
[v3]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/ext.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
openssl pkcs12 -export -legacy -out "$WORK/id.p12" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -passout "pass:$PASS" 2>/dev/null \
  || openssl pkcs12 -export -out "$WORK/id.p12" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -passout "pass:$PASS"

[ -f "$KEYCHAIN" ] || security create-keychain -p "$PASS" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"                  # no auto-lock
security unlock-keychain -p "$PASS" "$KEYCHAIN"
security import "$WORK/id.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KEYCHAIN" >/dev/null
# Add to the search list (keeps whatever is there).
CURRENT=$(security list-keychains -d user | tr -d '" ' | tr '\n' ' ')
security list-keychains -d user -s $CURRENT "$KEYCHAIN"
# Trust the certificate for code signing in this keychain so codesign does not warn.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem" 2>/dev/null || true
security find-identity -v -p codesigning | grep "$NAME" && echo "created identity '$NAME' in $KEYCHAIN"
