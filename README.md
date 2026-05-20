# AgentGateway Enterprise — GitOps Deployment

Production-grade GitOps pipeline for [Solo Enterprise AgentGateway](https://docs.solo.io/agentgateway/2.3.x/) managed by ArgoCD.

## Architecture

```
┌──────────────────────────────────────────────────────────────────────────┐
│                              ArgoCD                                      │
│  app-of-apps (agentgateway-platform)                                     │
│  ┌─────────────┐ ┌─────────────┐ ┌──────────┐ ┌───────┐ ┌───────────┐  │
│  │ gateway-api  │ │ agentgw     │ │ agentgw  │ │ vault │ │ external  │  │
│  │ crds (wave1) │ │ crds(wave2) │ │ cp(wave3)│ │(wave4)│ │ secrets(5)│  │
│  └─────────────┘ └─────────────┘ └──────────┘ └───────┘ └───────────┘  │
│  ┌──────────────┐ ┌────────────────────────────────────────────────┐    │
│  │  solo-ui     │ │ agentgateway-config (wave7)                    │    │
│  │  (wave6)     │ │  gateway / backends / routes / policies / ESO  │    │
│  └──────────────┘ └────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────────────┘
         Vault stores LLM API keys → ESO syncs them → K8s Secrets → AgentGateway
```

## Current Deployment Status

| Component | Namespace | Pods | Status |
|-----------|-----------|------|--------|
| AgentGateway Controller | agentgateway-system | `enterprise-agentgateway` | Running |
| AgentGateway Proxy | agentgateway-system | `agentgateway-proxy` | Running, PROGRAMMED |
| DGX Spark Gateway | agentgateway-system | `dgx-spark-gateway` | Running, PROGRAMMED |
| xAI Grok Gateway | agentgateway-system | `xai-grok-gateway` | Pending deploy |
| Ext-Auth / Cache / Rate Limiter | agentgateway-system | 3 pods | Running |
| Solo UI | agentgateway-system | `solo-enterprise-ui` (4 containers) | Running |
| Telemetry Collector + ClickHouse | agentgateway-system | 2 pods | Running |
| **HashiCorp Vault** | vault | `vault-0` (dev mode) | Running |
| **External Secrets Operator** | external-secrets | 3 pods (controller, webhook, cert) | Running |

### Cluster Nodes

| Role | Hostname | IP | OS |
|------|----------|----|----|
| Control Plane | talos-0yo-2th | `172.16.10.156` | Talos v1.11.5 |
| Worker | talos-9kw-b68 | `172.16.10.149` | Talos v1.11.5 |
| DGX Spark (local LLM) | — | `172.16.10.173` | — |

### Access (NodePort — bare-metal cluster)

| Service | URL | NodePort |
|---------|-----|----------|
| **Solo UI** | `http://172.16.10.149:30854/age/` | 30854 |
| **Gateway Proxy (OpenAI)** | `http://172.16.10.149:30160/` | 30160 |
| **DGX Spark Gateway** | `http://172.16.10.149:31944/` | 31944 |
| **xAI Grok Gateway** | `http://172.16.10.149:<NodePort>/` | TBD (assigned on deploy) |
| **Vault UI** | `http://172.16.10.149:31495/` | 31495 |
| **ArgoCD** | port-forward `kubectl port-forward svc/argocd-server -n argocd 8443:443` | — |

## Repository Structure

```
agentgateway-gitops/
├── argocd/
│   ├── app-of-apps.yaml              # Root Application — deploys everything
│   └── apps/
│       ├── gateway-api-crds.yaml      # Wave 1: Gateway API CRDs v1.5.0
│       ├── agentgateway-crds.yaml     # Wave 2: AgentGateway CRDs v2.3.3
│       ├── agentgateway-control-plane.yaml  # Wave 3: Control plane v2.3.3
│       ├── vault.yaml                 # Wave 4: HashiCorp Vault (dev mode)
│       ├── external-secrets.yaml      # Wave 5: External Secrets Operator
│       ├── solo-ui.yaml               # Wave 6: Solo UI management v0.3.19
│       └── agentgateway-config.yaml   # Wave 7: Runtime config (routes, backends, etc.)
├── config/
│   ├── gateway/
│   │   ├── gateway.yaml               # Gateway proxy listener (port 80 HTTP)
│   │   ├── dgx-spark-gateway.yaml     # Dedicated gateway for DGX Spark LLM
│   │   └── xai-grok-gateway.yaml     # Dedicated gateway for xAI Grok
│   ├── backends/
│   │   ├── openai.yaml                # OpenAI LLM backend (gpt-4o)
│   │   ├── dgx-spark-llm.yaml        # Local Qwen model on DGX Spark (172.16.10.173)
│   │   └── xai-grok.yaml            # xAI Grok backend (api.x.ai)
│   ├── routes/
│   │   ├── openai-route.yaml          # HTTPRoute mapping /openai → OpenAI backend
│   │   ├── dgx-spark-llm-route.yaml   # HTTPRoute mapping /spark → DGX Spark
│   │   └── xai-grok-route.yaml       # HTTPRoute mapping /grok → xAI Grok
│   ├── policies/
│   │   ├── tracing.yaml               # Distributed tracing via OTel to Solo collector
│   │   └── xai-grok-backend-tls.yaml  # BackendTLSPolicy for xAI Grok HTTPS
│   ├── external-secrets/
│   │   ├── cluster-secret-store.yaml  # ClusterSecretStore → Vault via K8s auth
│   │   ├── openai-external-secret.yaml # ExternalSecret: Vault → openai-secret
│   │   └── xai-external-secret.yaml   # ExternalSecret: Vault → xai-secret
│   └── secrets/                       # (empty — secrets managed by Vault now)
├── platform/
│   └── gateway-api-crds/
│       └── kustomization.yaml         # Kustomize ref to Gateway API v1.5.0 CRDs
├── scripts/
│   ├── setup-argocd.sh                # Install ArgoCD on a fresh cluster
│   ├── inject-license.sh              # Inject license key into manifests
│   └── configure-vault.sh             # Configure Vault KV engine, K8s auth, seed keys
├── skills/
│   └── agentgateway-gitops-deploy/
│       └── SKILL.md                   # Claude Code skill for this deployment
└── README.md
```

## What Each Component Does

### Platform Layer (Helm Charts via ArgoCD)

| Component | Chart | Version | Purpose |
|-----------|-------|---------|---------|
| **Gateway API CRDs** | upstream YAML | v1.5.0 | Kubernetes Gateway API types (Gateway, HTTPRoute, etc.) |
| **AgentGateway CRDs** | `enterprise-agentgateway-crds` | v2.3.3 | Custom types: `AgentgatewayBackend`, `EnterpriseAgentgatewayPolicy` |
| **Control Plane** | `enterprise-agentgateway` | v2.3.3 | Controller + proxy that processes Gateway API resources |
| **HashiCorp Vault** | `vault` | 0.32.0 | Secrets management — stores LLM API keys securely |
| **External Secrets Operator** | `external-secrets` | 0.16.2 | Syncs Vault secrets into Kubernetes Secrets automatically |
| **Solo UI** | `management` | 0.3.19 | Dashboard with tracing, playground, and route visualization |

### Config Layer (Plain YAML managed by ArgoCD)

| Resource | API Group | File | What It Does |
|----------|-----------|------|--------------|
| **Gateway** | `gateway.networking.k8s.io/v1` | `config/gateway/gateway.yaml` | Main proxy instance. Listens on port 80 HTTP. Routes to cloud LLM backends. |
| **Gateway (DGX Spark)** | `gateway.networking.k8s.io/v1` | `config/gateway/dgx-spark-gateway.yaml` | Dedicated proxy for the local DGX Spark LLM at `172.16.10.173:8000`. |
| **Gateway (xAI Grok)** | `gateway.networking.k8s.io/v1` | `config/gateway/xai-grok-gateway.yaml` | Dedicated proxy for xAI Grok API (`api.x.ai`). |
| **AgentgatewayBackend** | `agentgateway.dev/v1alpha1` | `config/backends/openai.yaml` | OpenAI backend — model `gpt-4o`. Auth via Vault-synced Secret. |
| **AgentgatewayBackend** | `agentgateway.dev/v1alpha1` | `config/backends/dgx-spark-llm.yaml` | Local Qwen/Qwen3.6-35B-A3B-FP8 on DGX Spark (`172.16.10.173:8000`). No auth required. |
| **AgentgatewayBackend** | `agentgateway.dev/v1alpha1` | `config/backends/xai-grok.yaml` | xAI Grok-4.3 backend (`api.x.ai:443`). Auth via Vault-synced Secret. |
| **HTTPRoute** | `gateway.networking.k8s.io/v1` | `config/routes/openai-route.yaml` | Maps `/openai` → OpenAI backend via main gateway. |
| **HTTPRoute** | `gateway.networking.k8s.io/v1` | `config/routes/dgx-spark-llm-route.yaml` | Maps `/spark` → DGX Spark backend via dedicated gateway. |
| **HTTPRoute** | `gateway.networking.k8s.io/v1` | `config/routes/xai-grok-route.yaml` | Maps `/grok` → xAI Grok backend via dedicated gateway. |
| **EnterpriseAgentgatewayPolicy** | `enterpriseagentgateway.solo.io/v1alpha1` | `config/policies/tracing.yaml` | Enables distributed tracing. Sends traces to the Solo telemetry collector (OTel gRPC :4317). 100% sampling. |
| **BackendTLSPolicy** | `gateway.networking.k8s.io/v1` | `config/policies/xai-grok-backend-tls.yaml` | Enables HTTPS to xAI Grok backend (`api.x.ai`). Uses system CA trust store. |
| **ClusterSecretStore** | `external-secrets.io/v1` | `config/external-secrets/cluster-secret-store.yaml` | Connects ESO to Vault via Kubernetes auth. Cluster-wide scope. |
| **ExternalSecret** | `external-secrets.io/v1` | `config/external-secrets/openai-external-secret.yaml` | Syncs OpenAI API key from Vault → K8s Secret `openai-secret`. Refreshes hourly. |
| **ExternalSecret** | `external-secrets.io/v1` | `config/external-secrets/xai-external-secret.yaml` | Syncs xAI API key from Vault → K8s Secret `xai-secret`. Refreshes hourly. |

## Deployment Order (Sync Waves)

ArgoCD deploys in order using sync-wave annotations:

1. **Wave 1** — Gateway API CRDs (types must exist before anything references them)
2. **Wave 2** — AgentGateway CRDs (custom types for backends and policies)
3. **Wave 3** — Control plane (controller that watches for Gateway/Route/Backend resources)
4. **Wave 4** — HashiCorp Vault (secrets store must be running before ESO can sync)
5. **Wave 5** — External Secrets Operator (syncs Vault secrets → K8s Secrets)
6. **Wave 6** — Solo UI (dashboard + telemetry collector + ClickHouse)
7. **Wave 7** — Config (gateway, backends, routes, policies, ExternalSecrets)

## Quick Start

### Prerequisites
- Kubernetes cluster with `kubectl` access
- `helm` 3.x
- `AGENTGATEWAY_LICENSE_KEY` environment variable set

### 1. Install ArgoCD
```bash
./scripts/setup-argocd.sh
```

### 2. Connect ArgoCD to this repo

Use a Kubernetes Secret (more reliable than the ArgoCD CLI, which can have gRPC timeout issues):
```bash
GH_TOKEN=$(gh auth token)
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: gitops-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  type: git
  url: https://github.com/sebastianmaniak/k8s-goose.git
  username: <github-user>
  password: ${GH_TOKEN}
EOF
```

### 3. Inject license key
```bash
export AGENTGATEWAY_LICENSE_KEY=<your-key>
./scripts/inject-license.sh
git add -A && git commit -m "Inject license" && git push
```

### 4. Deploy everything
```bash
kubectl apply -f argocd/app-of-apps.yaml
```

### 5. Verify
```bash
kubectl get applications -n argocd
kubectl get pods -n agentgateway-system
kubectl get gateway,httproute,agentgatewaybackend,enterpriseagentgatewaypolicy -n agentgateway-system
```

### 6. Access

**Via NodePort (bare-metal):**
```bash
# Solo UI
open http://172.16.10.149:30854/age/

# Gateway Proxy — OpenAI
curl http://172.16.10.149:30160/openai/v1/chat/completions \
  -H "content-type: application/json" \
  -d '{"model":"","messages":[{"role":"user","content":"Hello!"}]}' | jq

# DGX Spark Gateway — local Qwen model
curl http://172.16.10.149:31944/spark/v1/chat/completions \
  -H "content-type: application/json" \
  -d '{"model":"Qwen/Qwen3.6-35B-A3B-FP8","messages":[{"role":"user","content":"Hello!"}]}' | jq

# xAI Grok Gateway
curl http://172.16.10.149:<NodePort>/grok/v1/chat/completions \
  -H "content-type: application/json" \
  -d '{"model":"grok-4.3","messages":[{"role":"user","content":"Hello!"}]}' | jq
```

**Via port-forward (any cluster):**
```bash
# Solo UI
kubectl port-forward svc/solo-enterprise-ui -n agentgateway-system 4000:80
# Open http://localhost:4000/age/

# Gateway Proxy
kubectl port-forward deployment/agentgateway-proxy -n agentgateway-system 8080:80
curl localhost:8080/openai/v1/chat/completions ...
```

## Secrets Management (Vault)

LLM API keys are stored in HashiCorp Vault and automatically synced to Kubernetes Secrets by the External Secrets Operator. **No secrets are stored in Git.**

```
Vault (KV v2)                    ESO                         K8s Secret               AgentGateway
agentgateway/llm-keys/openai  →  ExternalSecret  →  openai-secret  →  AgentgatewayBackend
agentgateway/llm-keys/anthropic → ExternalSecret  →  anthropic-secret → AgentgatewayBackend
agentgateway/llm-keys/xai     →  ExternalSecret  →  xai-secret     →  AgentgatewayBackend
```

### Initial Setup (one-time)
```bash
./scripts/configure-vault.sh
```
This enables the KV engine, configures K8s auth for ESO, and seeds keys from env vars.

### Add or Update an API Key
```bash
# Store a key in Vault
kubectl exec -n vault vault-0 -- vault kv put agentgateway/llm-keys/openai Authorization="sk-your-real-key"

# ESO syncs it to K8s within the refresh interval (1h default, or force it):
kubectl annotate externalsecret openai-secret -n agentgateway-system force-sync=$(date +%s) --overwrite
```

### Add a New Provider Secret
1. Store the key in Vault:
```bash
kubectl exec -n vault vault-0 -- vault kv put agentgateway/llm-keys/anthropic Authorization="sk-ant-your-key"
```

2. Create an ExternalSecret in `config/external-secrets/`:
```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: anthropic-secret
  namespace: agentgateway-system
spec:
  refreshInterval: "1h"
  secretStoreRef:
    name: vault
    kind: ClusterSecretStore
  target:
    name: anthropic-secret
    creationPolicy: Owner
  data:
    - secretKey: Authorization
      remoteRef:
        key: llm-keys/anthropic
        property: Authorization
```

3. Commit and push — ArgoCD deploys the ExternalSecret, ESO creates the K8s Secret from Vault.

### List All Stored Keys
```bash
kubectl exec -n vault vault-0 -- vault kv list agentgateway/llm-keys
```

### Access Vault UI
```bash
open http://172.16.10.149:31495
# Token: root (dev mode)
```

## How to Upgrade

1. Update `targetRevision` in `argocd/apps/agentgateway-crds.yaml` and `argocd/apps/agentgateway-control-plane.yaml`
2. Update `targetRevision` in `argocd/apps/solo-ui.yaml` if a new UI version is available
3. Commit and push — ArgoCD auto-syncs the changes

```bash
sed -i 's/v2.3.3/v2.4.0/g' argocd/apps/agentgateway-crds.yaml argocd/apps/agentgateway-control-plane.yaml
git add -A && git commit -m "Upgrade AgentGateway to v2.4.0" && git push
```

## How to Add a New LLM Backend

1. Create a secret in `config/secrets/`:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: anthropic-secret
  namespace: agentgateway-system
type: Opaque
stringData:
  Authorization: <your-anthropic-key>
```

2. Create a backend in `config/backends/`:
```yaml
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: anthropic
  namespace: agentgateway-system
spec:
  ai:
    provider:
      anthropic:
        model: claude-sonnet-4-20250514
  policies:
    auth:
      secretRef:
        name: anthropic-secret
```

3. Create a route in `config/routes/`:
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: anthropic
  namespace: agentgateway-system
spec:
  parentRefs:
    - name: agentgateway-proxy
      namespace: agentgateway-system
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /anthropic
      backendRefs:
        - name: anthropic
          namespace: agentgateway-system
          group: agentgateway.dev
          kind: AgentgatewayBackend
```

4. Commit and push — ArgoCD deploys it automatically.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Pods stuck ContainerCreating | Stale istio-cni in CNI chain | Deploy privileged DaemonSet with `hostNetwork:true` to clean `/etc/cni/net.d/` |
| Solo UI helm template fails | Missing license key | Both control plane AND UI charts need `licensing.licenseKey` |
| ArgoCD CLI gRPC timeout | Port-forward instability (common on Talos) | Use kubectl Secret to add repo instead of `argocd repo add` CLI |
| HTTPRoute OutOfSync in ArgoCD | Gateway controller adds status fields | Normal — resource is healthy, ignore |
| No ExternalIP on services | No cloud LB on bare metal | Use NodePort access (already allocated) |
| ExternalSecret SecretSyncedError | ClusterSecretStore not ready yet | Wait for ESO pods, then `kubectl annotate externalsecret <name> -n agentgateway-system force-sync=$(date +%s) --overwrite` |
| Vault auth/kubernetes 403 | ESO SA not bound to Vault role | Re-run `./scripts/configure-vault.sh` to recreate the role |

## Security Notes

- **No plain secrets in Git.** All LLM API keys are stored in Vault and synced by ESO.
- Vault is running in **dev mode** (in-memory, root token `root`). For production:
  - Use Vault HA with Raft/Consul storage backend
  - Enable TLS
  - Use a proper unseal mechanism (auto-unseal with KMS)
  - Rotate the root token
- The AgentGateway license key is still embedded in ArgoCD Application manifests. For production, store it in Vault too and reference via an ExternalSecret.
