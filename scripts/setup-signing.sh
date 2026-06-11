#!/bin/bash
# Create a *stable* self-signed code-signing identity in the login keychain.
#
# Why: ad-hoc signing (`codesign -s -`) produces a different signature on every build,
# which makes macOS treat each rebuild as a new app and re-ask for Screen Recording
# permission. A fixed self-signed identity keeps the signature constant, so you grant
# permission once and never again. Runs once; it's a no-op if the identity already exists.
set -euo pipefail

IDENTITY="ClipThat Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# Note: no -v — the cert is self-signed/untrusted, so it won't show as "valid", but it's
# present and usable. Checking without -v prevents creating duplicates on re-runs.
if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "✓ Signing identity '$IDENTITY' already exists — nothing to do."
    exit 0
fi

echo "▸ Creating self-signed code-signing identity '$IDENTITY'…"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cfg.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[dn]
CN = ClipThat Dev
[v3]
basicConstraints   = critical,CA:false
keyUsage           = critical,digitalSignature
extendedKeyUsage   = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cfg.cnf" 2>/dev/null

openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$IDENTITY" -out "$TMP/id.p12" -passout pass:clipthat 2>/dev/null

# Import key+cert and pre-authorize codesign to use the key (avoids repeated prompts).
security import "$TMP/id.p12" -k "$KEYCHAIN" -P clipthat -T /usr/bin/codesign

echo ""
echo "✓ Created '$IDENTITY'."
echo "  (If a Keychain dialog appears while building, click \"Always Allow\".)"
