#!/usr/bin/env bash
# One-time: creates a self-signed code-signing certificate "Airflow Local Signing"
# in your login keychain, so rebuilt copies of Airflow keep their Microphone and
# Accessibility permissions. macOS will ask for your login password to trust it.
set -euo pipefail

NAME="Airflow Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning | grep -q "$NAME"; then
  echo "✔ \"$NAME\" already exists"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cnf"
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/cert.p12" -passout pass:airflow -name "$NAME"

security import "$WORK/cert.p12" -k "$KEYCHAIN" -P airflow -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo "✔ created \"$NAME\". Rebuild with: make app"
