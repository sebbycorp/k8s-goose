---
name: agentgateway-enterprise
description: Deploy and configure Solo Enterprise for AgentGateway (v2.3.x) on Kubernetes clusters. Use this skill whenever the user mentions agentgateway, solo.io gateway, AI gateway, LLM gateway, LLM proxy, MCP gateway, or enterprise gateway. Covers both direct Helm install and ArgoCD GitOps deployment, including Solo UI setup, LLM backend configuration (OpenAI, Anthropic, Azure, Bedrock), HTTPRoutes, policies (tracing, auth, rate limiting), Gateway API resources, and troubleshooting. Also use when upgrading from earlier agentgateway versions or adding new LLM backends to an existing deployment.
---

# Solo Enterprise for AgentGateway (v2.3.x)

Kubernetes-native API gateway for AI workloads built on the Gateway API. Routes to LLM providers, MCP servers, and HTTP backends with auth, rate limiting, observability, and tracing.

## Quick Reference

| Component | Chart | Version | OCI Registry |
|-----------|-------|---------|--------------|
| Gateway API CRDs | upstream YAML | v1.5.0 | `github.com/kubernetes-sigs/gateway-api` |
| AgentGateway CRDs | `enterprise-agentgateway-crds` | v2.3.3 | `us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts` |
| Control Plane | `enterprise-agentgateway` | v2.3.3 | `us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts` |
| Solo UI | `management` | 0.3.19 | `us-docker.pkg.dev/solo-public/solo-enterprise-helm/charts` |

| Resource | API Group | Purpose |
|----------|-----------|---------|
| Gateway | `gateway.networking.k8s.io/v1` | Proxy instance with listeners |
| HTTPRoute | `gateway.networking.k8s.io/v1` | Route rules mapping paths to backends |
| AgentgatewayBackend | `agentgateway.dev/v1alpha1` | LLM/MCP/HTTP backend definition |
| EnterpriseAgentgatewayPolicy | `enterpriseagentgateway.solo.io/v1alpha1` | Policies (tracing, auth, rate limiting) |

All resources go in `agentgateway-system` namespace by default.

## Prerequisites

- Kubernetes cluster (Kind, EKS, GKE, AKS, Talos)
- kubectl (within one minor version of cluster)
- helm 3.x
- License key: `AGENTGATEWAY_LICENSE_KEY` env var

## Installation Path A: Direct Helm

### 1. Gateway API CRDs
```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.0/standard-install.yaml
```

### 2. AgentGateway CRDs
```bash
helm upgrade -i --create-namespace \
  --namespace agentgateway-system \
  --version v2.3.3 enterprise-agentgateway-crds \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway-crds
```

### 3. Control Plane
```bash
helm upgrade -i -n agentgateway-system enterprise-agentgateway \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway \
  --version v2.3.3 \
  --set-string licensing.licenseKey=${AGENTGATEWAY_LICENSE_KEY}
```

### 4. Solo UI (requires license key too)
```bash
helm upgrade -i management \
  oci://us-docker.pkg.dev/solo-public/solo-enterprise-helm/charts/management \
  --namespace agentgateway-system \
  --create-namespace \
  --version 0.3.19 \
  --set cluster="mgmt-cluster" \
  --set products.agentgateway.enabled=true \
  --set-string licensing.licenseKey=${AGENTGATEWAY_LICENSE_KEY}
```

### 5. Verify
```bash
kubectl get pods -n agentgateway-system
kubectl get gatewayclass enterprise-agentgateway
```

## Installation Path B: ArgoCD GitOps

Uses app-of-apps pattern with sync-wave ordering. See `references/argocd-gitops.md` for the full repo structure and all ArgoCD Application manifests.

### ArgoCD Setup
```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.12.3/manifests/install.yaml
```

### Connect Private Repo (use Secret, not CLI — the CLI often has gRPC timeout issues)
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
  url: https://github.com/<org>/<repo>.git
  username: <github-user>
  password: ${GH_TOKEN}
EOF
```

### Deploy via App-of-Apps
```bash
kubectl apply -f argocd/app-of-apps.yaml
kubectl get applications -n argocd    # Watch sync status
```

### ArgoCD Application Structure (sync-wave ordered)
```
Wave 1: gateway-api-crds          (Kustomize → upstream CRDs)
Wave 2: agentgateway-crds         (Helm → enterprise-agentgateway-crds v2.3.3)
Wave 3: agentgateway-control-plane (Helm → enterprise-agentgateway v2.3.3 + license)
Wave 4: solo-ui                   (Helm → management v0.3.19 + license)
Wave 5: agentgateway-config       (Plain YAML → gateway, backends, routes, policies)
```

### GitOps Repo Structure
```
agentgateway-gitops/
├── argocd/
│   ├── app-of-apps.yaml
│   └── apps/                    # One ArgoCD Application per wave
├── config/
│   ├── gateway/                 # Gateway resources
│   ├── backends/                # AgentgatewayBackend per provider
│   ├── routes/                  # HTTPRoute per backend
│   ├── policies/                # EnterpriseAgentgatewayPolicy
│   └── secrets/                 # API key secrets (use SealedSecrets in prod)
├── platform/gateway-api-crds/   # Kustomize ref
└── scripts/
```

## Gateway Setup

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: agentgateway-proxy
  namespace: agentgateway-system
spec:
  gatewayClassName: enterprise-agentgateway
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: All
```

## LLM Backend Pattern (repeat per provider)

### Secret
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: <provider>-secret
  namespace: agentgateway-system
type: Opaque
stringData:
  Authorization: <api-key>
```

### AgentgatewayBackend
```yaml
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: <provider>
  namespace: agentgateway-system
spec:
  ai:
    provider:
      openai:           # or: anthropic, azure, bedrock
        model: gpt-4o   # provider-specific model name
  policies:
    auth:
      secretRef:
        name: <provider>-secret
```

### HTTPRoute
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: <provider>
  namespace: agentgateway-system
spec:
  parentRefs:
    - name: agentgateway-proxy
      namespace: agentgateway-system
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /<provider>
      backendRefs:
        - name: <provider>
          namespace: agentgateway-system
          group: agentgateway.dev
          kind: AgentgatewayBackend
```

### Test
```bash
kubectl port-forward deployment/agentgateway-proxy -n agentgateway-system 8080:80 &
curl "localhost:8080/<provider>/v1/chat/completions" -H content-type:application/json \
  -d '{"model":"","messages":[{"role":"user","content":"Hello!"}]}' | jq
```

## Tracing Policy (requires Solo UI running)

```yaml
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: tracing
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: agentgateway-proxy
  frontend:
    tracing:
      backendRef:
        name: solo-enterprise-telemetry-collector
        namespace: agentgateway-system
        kind: Service
        port: 4317
      randomSampling: "true"
```

## Solo UI Access
```bash
kubectl port-forward svc/solo-enterprise-ui -n agentgateway-system 4000:80
# Open http://localhost:4000/age/
```

## Upgrading

Update chart versions in helm commands or ArgoCD Application `targetRevision` fields:
```bash
# Helm
helm upgrade -i ... --version v<new-version> ...

# ArgoCD GitOps — edit targetRevision in apps/, commit, push
```

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Pods stuck ContainerCreating | Stale istio-cni in CNI chain | Deploy privileged DaemonSet with `hostNetwork:true` to rewrite `/etc/cni/net.d/10-flannel.conflist` removing istio-cni plugin, then restart pods |
| Solo UI helm template fails | Missing license key | Add `--set-string licensing.licenseKey=...` to UI chart too |
| ArgoCD CLI gRPC timeout | Port-forward instability (common on Talos) | Use kubectl Secret to add repo instead of `argocd repo add` CLI |
| HTTPRoute shows OutOfSync in ArgoCD | Gateway controller adds status fields | Normal — resource is healthy, ArgoCD detects server-side diff |
| ArgoCD pods fail after CNI fix | Old pods have stale network namespace | `kubectl rollout restart deploy -n argocd && kubectl rollout restart statefulset -n argocd` |
| GatewayClass not found | CRDs not installed yet | Ensure Gateway API CRDs + AgentGateway CRDs install before control plane |

## Cleanup

```bash
# Config
kubectl delete AgentgatewayBackend,HTTPRoute,EnterpriseAgentgatewayPolicy --all -n agentgateway-system
kubectl delete gateway agentgateway-proxy -n agentgateway-system

# Helm charts (reverse order)
helm uninstall management -n agentgateway-system
helm uninstall enterprise-agentgateway -n agentgateway-system
helm uninstall enterprise-agentgateway-crds -n agentgateway-system

# ArgoCD (if used)
kubectl delete -f argocd/app-of-apps.yaml
```
