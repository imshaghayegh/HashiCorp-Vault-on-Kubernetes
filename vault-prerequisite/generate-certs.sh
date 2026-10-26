#!/bin/bash
# generate-certs.sh
 
NAMESPACE="vault"
SERVICE="vault"
SECRET_NAME="vault-tls"
TMPDIR=$(mktemp -d)
 
# Create CA
openssl genrsa -out ${TMPDIR}/ca.key 4096
openssl req -x509 -new -nodes -key ${TMPDIR}/ca.key -sha256 -days 3650 \
    -out ${TMPDIR}/ca.crt \
    -subj "/C=IR/ST=Tehran/L=Tehran/O=Vault/CN=Vault CA"
 
# Create Server Key
openssl genrsa -out ${TMPDIR}/vault.key 4096
 
# Create CSR config
cat > ${TMPDIR}/csr.conf <<EOF
[req]
default_bits = 4096
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = v3_req
 
[dn]
C = IR
ST = Tehran
L = Tehran
O = Vault
CN = vault
 
[v3_req]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @alt_names
 
[alt_names]
DNS.1 = ${SERVICE}
DNS.2 = ${SERVICE}.${NAMESPACE}
DNS.3 = ${SERVICE}.${NAMESPACE}.svc
DNS.4 = ${SERVICE}.${NAMESPACE}.svc.cluster.local
DNS.5 = ${SERVICE}-0.${SERVICE}-internal
DNS.6 = ${SERVICE}-1.${SERVICE}-internal
DNS.7 = ${SERVICE}-2.${SERVICE}-internal
DNS.8 = ${SERVICE}-0.${SERVICE}-internal.${NAMESPACE}.svc.cluster.local
DNS.9 = ${SERVICE}-1.${SERVICE}-internal.${NAMESPACE}.svc.cluster.local
DNS.10 = ${SERVICE}-2.${SERVICE}-internal.${NAMESPACE}.svc.cluster.local
DNS.11 = *.${SERVICE}-internal
DNS.12 = *.${SERVICE}-internal.${NAMESPACE}.svc.cluster.local
DNS.13 = localhost
IP.1 = 127.0.0.1
EOF
 
# Create CSR
openssl req -new -key ${TMPDIR}/vault.key \
    -out ${TMPDIR}/vault.csr \
    -config ${TMPDIR}/csr.conf
 
# Certificate sign
openssl x509 -req -in ${TMPDIR}/vault.csr \
    -CA ${TMPDIR}/ca.crt -CAkey ${TMPDIR}/ca.key \
    -CAcreateserial -out ${TMPDIR}/vault.crt \
    -days 3650 -sha256 \
    -extfile ${TMPDIR}/csr.conf -extensions v3_req
 
# Create Secret in the Kubernetes Cluster
kubectl create secret generic ${SECRET_NAME} \
    --namespace=${NAMESPACE} \
    --from-file=vault.key=${TMPDIR}/vault.key \
    --from-file=vault.crt=${TMPDIR}/vault.crt \
    --from-file=vault.ca=${TMPDIR}/ca.crt
 
# Store files for next use
mkdir -p ./vault-certs
cp ${TMPDIR}/ca.crt ./vault-certs/
cp ${TMPDIR}/vault.crt ./vault-certs/
cp ${TMPDIR}/vault.key ./vault-certs/
 
echo "TLS certificates created and stored in vault-certs/ directory"
echo "Secret ${SECRET_NAME} created in namespace ${NAMESPACE}"
 
# Clears
rm -rf ${TMPDIR}
