# Vault HA on Kubernetes

Minimal Helm deployment of HashiCorp Vault using Raft storage, TLS and the local-path StorageClass.

## Prerequisites

- Kubernetes, `kubectl`, Helm and OpenSSL
- Access to the image registries configured in `values.yaml` and `vault-prerequisite/local-path-storage.yaml`

## Install

Run from this chart directory.

### 1. Create namespaces

```bash
kubectl create namespace vault
kubectl create namespace local-path-storage
```

### 2. Create registry secrets

Create **`nexus-prod`** in `local-path-storage` (used by the provisioner manifest) and **`nexus-secret`** in `vault` (used by `values.yaml`). Use the registry host and credentials appropriate for each configured image source.

```bash
kubectl create secret docker-registry nexus-prod \
  --docker-server=repo.bmi.ir:443 \
  --docker-username='<USERNAME>' \
  --docker-password='<PASSWORD>' -n local-path-storage

kubectl create secret docker-registry nexus-secret \
  --docker-server=linuxdocker.srvdc.ir \
  --docker-username='<USERNAME>' \
  --docker-password='<PASSWORD>' -n vault
```

### 3. Install storage provisioner

```bash
kubectl apply -f vault-prerequisite/local-path-storage.yaml
kubectl get storageclass
```

### 4. Create TLS Secret

The TLS script assumes the Helm release is called `vault`.

```bash
cd vault-prerequisite
chmod +x generate-certs.sh
./generate-certs.sh
cd ..
```

Keep the generated `vault-certs/` directory private; do not commit the private keys.

### 5. Install Vault

```bash
helm dependency build .
helm upgrade --install vault . -n vault -f values.yaml
kubectl get pods,svc,pvc -n vault
```

### 6. Initialize and unseal (new cluster only)

```bash
kubectl exec -n vault vault-0 -- vault operator init
kubectl exec -n vault vault-0 -- vault operator unseal
```

Safeguard the init output. Provide the required unseal key shares and unseal the other Vault nodes as needed. Do **not** initialize an existing cluster again.

## Access

Vault UI: `https://<NODE_IP>:30200` (self-signed certificate).

## Notes

- Default values: 3 Vault replicas, Raft storage, TLS, local-path PVCs and NodePort 30200.
- Auto-unseal is not configured. Production environments require secure key handling, appropriate certificate management, storage design and backups.
- `templates/cluster-secret-store.yaml` is included unchanged from the source chart; review it if you enable external secrets integration.
