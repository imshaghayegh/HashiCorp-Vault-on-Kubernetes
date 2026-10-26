# HashiCorp Vault on Kubernetes

## Overview

HashiCorp Vault centralizes the protection and lifecycle management of sensitive information, including database credentials, API keys, service tokens, TLS certificates, and cryptographic keys. It provides encrypted storage, identity-aware access, policy enforcement, and audit capabilities instead of distributing secrets across application code and configuration files.

Vault supports authentication through Kubernetes, LDAP, OIDC and other identity providers. Once authenticated, a client receives a token with policies that define its authorized operations.

## Capabilities

| Capability | Description |
| --- | --- |
| Third-party secrets | Generates short-lived credentials for supported databases and cloud platforms. |
| Certificates and PKI | Issues, renews, and revokes certificates through the PKI secrets engine. |
| Identity and authentication | Associates authenticated clients with identities, groups, policies, and tokens. |
| Static secrets | Stores versioned application credentials in KV; rotation requires an appropriate workflow or integration. |
| Transit encryption | Performs encryption, decryption, signing, and verification through APIs without storing application plaintext. |
| Auditing | Records requests and responses through configured audit devices, with sensitive fields protected. |
| Compliance support | Provides security controls useful for compliance programs; actual certification depends on the deployment and applicable edition/configuration. |

Common uses include secret management, centralized secret storage, access control, dynamic credentials, certificate issuance, identity-based access, encryption-as-a-service, audit logging, and Kubernetes application integration.

## Vault lifecycle

1. **Initialization:** A new Shamir-sealed Vault generates recovery material in the form of unseal-key shares and an initial root token.
2. **Sealed:** The barrier remains locked and application secrets are unavailable.
3. **Unseal:** A threshold of unseal-key shares unlocks the barrier. An appropriately configured external seal may perform this operation automatically.
4. **Operational:** Authenticated requests are evaluated against policies.

### Shamir's Secret Sharing

Shamir's Secret Sharing divides the unseal material into *m* shares with an *n*-share reconstruction threshold. This deployment uses five shares and a threshold of three:

```bash
vault operator init -key-shares=5 -key-threshold=3
```

No single share is sufficient to unseal Vault.

## Architecture

The proposed long-term design separates two independent Vault clusters, each with integrated Raft storage:

- **Main Vault:** KV, PKI, authentication, access policies, and application-facing secret management.
- **Transit Vault:** Dedicated cryptographic services and a possible transit auto-unseal provider for Main Vault.

The separation provides independent administrative and operational boundaries, dedicated resource scaling, distinct audit configurations, and reduced blast radius when supported by network segmentation and separate credentials. Main Vault's availability during restart depends on Transit Vault's availability when transit auto-unseal is configured. Neither a quantified latency reduction nor guaranteed isolation follows from separation alone.

**Implementation covered here:** one three-replica Vault HA cluster with Raft, TLS, and **manual Shamir unseal**. The second Transit cluster and transit auto-unseal are architectural targets, **not** included in the deployment manifests below.

## Repository layout

```text
.
├── README.md
├── .gitignore
├── manifests/
│   └── 00-vault-namespace.yaml
├── helm/
│   ├── local-path-values.yaml
│   └── vault-values.yaml
└── scripts/
    └── generate-certs.sh
```

## Kubernetes deployment

### 1. Namespace

```bash
kubectl apply -f manifests/00-vault-namespace.yaml
```

### 2. Self-signed TLS certificates

The certificate script generates a private self-signed CA and a CA-signed server certificate with SAN entries for Vault services and StatefulSet pod DNS names, then creates the `vault-tls` Kubernetes Secret.

```bash
chmod +x scripts/generate-certs.sh
./scripts/generate-certs.sh
kubectl get secret vault-tls -n vault
```

Certificate paths used by the Vault server are `/vault/userconfig/vault-tls/tls.crt`, `/vault/userconfig/vault-tls/tls.key`, and `/vault/userconfig/vault-tls/ca.crt`.

### 3. Local persistent storage

The deployment uses the Rancher Local Path Provisioner, installed independently of the Vault namespace. Its StorageClass is named `local-path` and is referenced by Vault's Raft PVCs.

```bash
git clone https://github.com/rancher/local-path-provisioner.git
helm upgrade --install local-path-provisioner \
  ./local-path-provisioner/deploy/chart/local-path-provisioner \
  --namespace local-path-storage --create-namespace \
  -f helm/local-path-values.yaml
kubectl get storageclass
kubectl get pods -n local-path-storage
```

The provisioner chart and images must be mirrored for offline environments. Pin the upstream repository to a tested release and verify chart values before deployment. The provisioner writes data to local node storage, so node failure does not automatically preserve the lost node's local volume.

### 4. Private registry authentication

For a private Nexus registry, create an image pull Secret in the Vault namespace. Provide credentials through prompts/environment management; do not commit them to Git:

```bash
kubectl -n vault create secret docker-registry nexus-prod \
  --docker-server=repo.sadad.co.ir \
  --docker-username='<NEXUS_USERNAME>' \
  --docker-password='<NEXUS_PASSWORD>'
```

Image references and tags in `helm/vault-values.yaml` must be updated to the images already mirrored to that registry. The image-pull Secret applies only to namespaces where it exists.

### 5. Helm deployment

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
helm upgrade --install vault hashicorp/vault \
  --namespace vault --values helm/vault-values.yaml
```

Offline installation using the chart artifact included in the deployment record:

```bash
helm upgrade --install vault ./vault-0.28.1.tgz \
  --namespace vault --values helm/vault-values.yaml
```

Verify the release and pods:

```bash
helm status vault -n vault
kubectl get pods -n vault
kubectl logs vault-0 -n vault --tail=50
kubectl exec -n vault vault-0 -- vault status
```

Vault server pods may remain `Running` but `0/1 Ready` until initialization, unseal, and Raft cluster formation complete. The injector may be ready independently.

### 6. Initialize and unseal

Initialize **only once**, on a new and uninitialized Raft cluster:

```bash
umask 077
kubectl exec -n vault vault-0 -- vault operator init \
  -key-shares=5 -key-threshold=3 -format=json > vault-init.json
```

Store `vault-init.json` in approved secure storage. It contains unseal shares and an initial root token; it must not be committed to Git.

The following commands use local shell variables for the three required shares. Avoid enabling shell tracing or storing the commands with expanded secrets in shell history.

```bash
UNSEAL_KEY_1=$(jq -r '.unseal_keys_b64[0]' vault-init.json)
UNSEAL_KEY_2=$(jq -r '.unseal_keys_b64[1]' vault-init.json)
UNSEAL_KEY_3=$(jq -r '.unseal_keys_b64[2]' vault-init.json)

for pod in vault-0 vault-1 vault-2; do
  kubectl exec -n vault "$pod" -- vault operator unseal "$UNSEAL_KEY_1"
  kubectl exec -n vault "$pod" -- vault operator unseal "$UNSEAL_KEY_2"
  kubectl exec -n vault "$pod" -- vault operator unseal "$UNSEAL_KEY_3"
done

unset UNSEAL_KEY_1 UNSEAL_KEY_2 UNSEAL_KEY_3
```

The provided Vault HA configuration uses `retry_join` for Raft discovery. In deployments without functioning auto-join, follower nodes must be explicitly joined to the initialized leader **before** unsealing them. Use the `vault operator raft join` command and a valid TLS trust configuration if that situation arises.

### 7. Validation

```bash
kubectl exec -n vault vault-0 -- vault status
kubectl exec -n vault vault-0 -- vault operator raft list-peers
kubectl get pods -n vault
```

Expected state: `Initialized: true`, `Sealed: false`, `Storage Type: raft`, and a three-member cluster with one leader and two followers, after successful joins and authentication.

`vault operator raft list-peers` requires appropriate Vault privileges. Authenticate with an authorized token if the command returns HTTP 403; use the initial root token only for bootstrap and then move to restricted administrative policies.

## Deployment components

| Component | Configuration |
| --- | --- |
| Vault Helm chart | `0.28.1` offline artifact recorded in the original procedure |
| Vault servers | Three replicas |
| Storage | Integrated Storage (Raft) |
| TLS | CA-signed certificates generated from a local self-signed CA |
| StorageClass | `local-path` |
| Image pull | `nexus-prod` Secret for private registry images |
| Unseal | Shamir 5 shares, threshold 3 |
| Agent Injector | Enabled |

## References

- [Vault Helm chart](https://github.com/hashicorp/vault-helm)
- [Vault HA with Raft](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/helm/examples/ha-with-raft)
- [Vault HA with TLS](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/helm/examples/ha-tls)
- [Rancher Local Path Provisioner](https://github.com/rancher/local-path-provisioner)
