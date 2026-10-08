#!/bin/sh
# Creates a code signing certificate for local builds, once per Mac.
#
# macOS remembers Screen Recording and file access permissions by an app's signature. Ad-hoc
# builds get a new signature every time, so every rebuild asks again. Signed with this
# certificate, every build has the same signature, so permissions are granted once.
#
# The certificate is self-signed, lives only in your login keychain and is only used by
# scripts/build.sh. To remove it, delete "WoW Session Recorder Local Signing" in Keychain Access.
set -eu

NAME="WoW Session Recorder Local Signing"
KEYCHAIN="${KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "\"$NAME\" is already in your keychain."
    exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.conf" <<EOF
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

# Valid for 20 years.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$WORK/cert.conf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
PASS=$(/usr/bin/openssl rand -hex 16)
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
    -out "$WORK/identity.p12" -passout "pass:$PASS"

# Let codesign use the key.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null

echo "Added \"$NAME\" to your keychain."
echo "scripts/build.sh now signs with it. The first build asks for permissions once more;"
echo "if macOS asks whether codesign may use the key, enter your password and choose Always Allow."
