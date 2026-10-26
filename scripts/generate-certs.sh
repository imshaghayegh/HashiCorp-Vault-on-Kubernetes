#!/usr/bin/env bash
set -euo pipefail
umask 077

NAMESPACE="${NAMESPACE:-vault}"
SECRET_NAME="${SECRET_NAME:-vault-tls}"
CERT_DIR="${CERT_DIR:-./.local-certs}"
mkdir -p "$CERT_DIR"

openssl genrsa -out "$CERT_DIR/ca.key" 4096
openssl req -x509 -new -sha256 -days 3650 \
  -key "$CERT_DIR/ca.key" -out "$CERT_DIR/ca.crt" \
  -subj "/CN=Vault Local CA"

cat > "$CERT_DIR/server.ext" <<'EXT'
subjectAltName = @alt_names
extendedKeyUsage = serverAuth,clientAuth
keyUsage = critical,digitalSignature,keyEncipherment
basicConstraints = critical,CA:false

[alt_names]
DNS.1 = vault
DNS.2 = vault.vault
DNS.3 = vault.vault.svc
DNS.4 = vault.vault.svc.cluster.local
DNS.5 = vault-active
DNS.6 = vault-active.vault.svc
DNS.7 = vault-internal
DNS.8 = vault-internal.vault.svc
DNS.9 = vault-0.vault-internal
DNS.10 = vault-1.vault-internal
DNS.11 = vault-2.vault-internal
DNS.12 = vault-0.vault-internal.vault.svc
DNS.13 = vault-1.vault-internal.vault.svc
DNS.14 = vault-2.vault-internal.vault.svc
DNS.15 = localhost
IP.1 = 127.0.0.1
EXT

openssl genrsa -out "$CERT_DIR/tls.key" 4096
openssl req -new -key "$CERT_DIR/tls.key" -out "$CERT_DIR/tls.csr" \
  -subj "/CN=vault.vault.svc"
openssl x509 -req -in "$CERT_DIR/tls.csr" -CA "$CERT_DIR/ca.crt" \
  -CAkey "$CERT_DIR/ca.key" -CAcreateserial -out "$CERT_DIR/tls.crt" \
  -days 365 -sha256 -extfile "$CERT_DIR/server.ext"

kubectl -n "$NAMESPACE" create secret generic "$SECRET_NAME" \
  --from-file=tls.crt="$CERT_DIR/tls.crt" \
  --from-file=tls.key="$CERT_DIR/tls.key" \
  --from-file=ca.crt="$CERT_DIR/ca.crt" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Created/updated $NAMESPACE/$SECRET_NAME. Local private keys remain in $CERT_DIR."
