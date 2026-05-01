# AgentRegistry Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy AgentRegistry into the k8s-goose cluster as a discovery and management layer for MCP servers, fitting the existing ArgoCD GitOps pattern.

**Architecture:** AgentRegistry deploys as a wave 8 Helm chart (OCI from GHCR) into `agentgateway-system`. A wave 9 ArgoCD app deploys a Kubernetes Job that registers the two existing MCP servers via the AgentRegistry REST API. No existing files are modified.

**Tech Stack:** Helm (OCI), ArgoCD sync waves, Kubernetes Jobs, AgentRegistry v0.3.3, curl for REST API registration

**Important path constraint:** The existing `agentgateway-config` (wave 7) syncs everything under `config/` recursively. All agentregistry K8s resources and non-K8s reference files must live outside `config/` — under a top-level `agentregistry/` directory — to avoid wave 7 picking them up or failing on non-K8s YAML.

---

### Task 1: Create AgentRegistry ArgoCD Application (Wave 8)

**Files:**
- Create: `argocd/apps/agentregistry.yaml`

**Context:** Follows the same pattern as `argocd/apps/vault.yaml` (Helm chart via ArgoCD) but uses an OCI registry source. The chart is published at `oci://ghcr.io/agentregistry-dev/agentregistry/charts`. Key overrides: expose MCP port (31313) as NodePort so external tools can discover servers.

- [ ] **Step 1: Create the ArgoCD Application manifest**

Create `argocd/apps/agentregistry.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: agentregistry
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "8"
spec:
  project: default
  source:
    chart: agentregistry
    repoURL: oci://ghcr.io/agentregistry-dev/agentregistry/charts
    targetRevision: "0.3.3"
    helm:
      parameters:
        - name: service.type
          value: NodePort
        - name: service.nodePorts.mcp
          value: "31313"
        - name: database.postgres.bundled.enabled
          value: "true"
        - name: rbac.watchedNamespaces[0]
          value: agentgateway-system
  destination:
    namespace: agentgateway-system
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

- [ ] **Step 2: Validate YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('argocd/apps/agentregistry.yaml'))"`
Expected: No output (valid YAML)

- [ ] **Step 3: Commit**

```bash
git add argocd/apps/agentregistry.yaml
git commit -m "Add AgentRegistry ArgoCD application (wave 8)"
```

---

### Task 2: Create MCP Server Registration Reference Manifests

**Files:**
- Create: `agentregistry/manifests/mcp-server-everything.yaml`
- Create: `agentregistry/manifests/mcp-website-fetcher.yaml`
- Create: `agentregistry/manifests/remote-servers.yaml`

**Context:** These are AgentRegistry `ar.dev/v1alpha1` resource definitions — NOT Kubernetes CRDs. They live under `agentregistry/manifests/` (outside `config/` to avoid wave 7 conflicts). They serve as human-readable reference and are embedded into the registration Job's ConfigMap (Task 3). They are NOT applied by ArgoCD directly.

- [ ] **Step 1: Create the manifests directory**

Run: `mkdir -p agentregistry/manifests`

- [ ] **Step 2: Create mcp-server-everything registration**

Create `agentregistry/manifests/mcp-server-everything.yaml`:

```yaml
apiVersion: ar.dev/v1alpha1
kind: MCPServer
metadata:
  name: mcp-server-everything
  version: 1.0.0
  labels:
    platform: agentgateway
    environment: dev
spec:
  description: "Demo MCP server with sample tools, resources, and prompts for testing"
  image: node:20-alpine
  transport: streamable-http
```

- [ ] **Step 3: Create mcp-website-fetcher registration**

Create `agentregistry/manifests/mcp-website-fetcher.yaml`:

```yaml
apiVersion: ar.dev/v1alpha1
kind: MCPServer
metadata:
  name: mcp-website-fetcher
  version: 1.0.0
  labels:
    platform: agentgateway
    environment: dev
spec:
  description: "Fetches and extracts content from websites via MCP"
  image: ghcr.io/peterj/mcp-website-fetcher:main
  transport: sse
```

- [ ] **Step 4: Create remote server endpoint registrations**

Create `agentregistry/manifests/remote-servers.yaml`:

```yaml
apiVersion: ar.dev/v1alpha1
kind: RemoteMCPServer
metadata:
  name: mcp-server-everything-remote
  version: 1.0.0
  labels:
    platform: agentgateway
    environment: dev
spec:
  description: "In-cluster MCP server everything (streamable-http)"
  url: "http://mcp-server-everything.agentgateway-system.svc.cluster.local:3001"
  transport: streamable-http
---
apiVersion: ar.dev/v1alpha1
kind: RemoteMCPServer
metadata:
  name: mcp-website-fetcher-remote
  version: 1.0.0
  labels:
    platform: agentgateway
    environment: dev
spec:
  description: "In-cluster website fetcher (SSE)"
  url: "http://mcp-website-fetcher.agentgateway-system.svc.cluster.local:80"
  transport: sse
```

- [ ] **Step 5: Validate all YAML files**

Run: `for f in agentregistry/manifests/*.yaml; do echo "--- $f ---"; python3 -c "import yaml, sys; list(yaml.safe_load_all(open('$f')))" && echo "OK"; done`
Expected: All files print "OK"

- [ ] **Step 6: Commit**

```bash
git add agentregistry/manifests/
git commit -m "Add AgentRegistry MCP server registration manifests"
```

---

### Task 3: Create the Registration Job and ConfigMap

**Files:**
- Create: `agentregistry/k8s/registration-job.yaml`

**Context:** This file contains a ConfigMap (with embedded registration YAML) and a Kubernetes Job. The Job's init container waits for AgentRegistry's health endpoint, then the main container POSTs each manifest to the REST API. Both are valid K8s resources that ArgoCD can sync. Lives under `agentregistry/k8s/` (outside `config/`).

- [ ] **Step 1: Create the k8s directory**

Run: `mkdir -p agentregistry/k8s`

- [ ] **Step 2: Create the ConfigMap and Job**

Create `agentregistry/k8s/registration-job.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: agentregistry-registrations
  namespace: agentgateway-system
data:
  mcp-server-everything.yaml: |
    apiVersion: ar.dev/v1alpha1
    kind: MCPServer
    metadata:
      name: mcp-server-everything
      version: 1.0.0
      labels:
        platform: agentgateway
        environment: dev
    spec:
      description: "Demo MCP server with sample tools, resources, and prompts for testing"
      image: node:20-alpine
      transport: streamable-http
  mcp-website-fetcher.yaml: |
    apiVersion: ar.dev/v1alpha1
    kind: MCPServer
    metadata:
      name: mcp-website-fetcher
      version: 1.0.0
      labels:
        platform: agentgateway
        environment: dev
    spec:
      description: "Fetches and extracts content from websites via MCP"
      image: ghcr.io/peterj/mcp-website-fetcher:main
      transport: sse
  remote-mcp-server-everything.yaml: |
    apiVersion: ar.dev/v1alpha1
    kind: RemoteMCPServer
    metadata:
      name: mcp-server-everything-remote
      version: 1.0.0
      labels:
        platform: agentgateway
        environment: dev
    spec:
      description: "In-cluster MCP server everything (streamable-http)"
      url: "http://mcp-server-everything.agentgateway-system.svc.cluster.local:3001"
      transport: streamable-http
  remote-mcp-website-fetcher.yaml: |
    apiVersion: ar.dev/v1alpha1
    kind: RemoteMCPServer
    metadata:
      name: mcp-website-fetcher-remote
      version: 1.0.0
      labels:
        platform: agentgateway
        environment: dev
    spec:
      description: "In-cluster website fetcher (SSE)"
      url: "http://mcp-website-fetcher.agentgateway-system.svc.cluster.local:80"
      transport: sse
---
apiVersion: batch/v1
kind: Job
metadata:
  name: agentregistry-register-mcpservers
  namespace: agentgateway-system
spec:
  backoffLimit: 3
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: OnFailure
      initContainers:
        - name: wait-for-registry
          image: curlimages/curl:8.13.0
          command:
            - sh
            - -c
            - |
              echo "Waiting for AgentRegistry to be ready..."
              until curl -sf http://agentregistry.agentgateway-system.svc.cluster.local:12121/healthz; do
                echo "AgentRegistry not ready, retrying in 5s..."
                sleep 5
              done
              echo "AgentRegistry is ready!"
      containers:
        - name: register
          image: curlimages/curl:8.13.0
          command:
            - sh
            - -c
            - |
              REGISTRY_URL="http://agentregistry.agentgateway-system.svc.cluster.local:12121"
              echo "Registering MCP servers with AgentRegistry..."
              for manifest in /registrations/*.yaml; do
                echo "--- Applying $(basename $manifest) ---"
                curl -sf -X PUT \
                  -H "Content-Type: application/yaml" \
                  -d @"$manifest" \
                  "$REGISTRY_URL/v0/apply"
                echo ""
              done
              echo "All registrations complete!"
          volumeMounts:
            - name: registrations
              mountPath: /registrations
              readOnly: true
      volumes:
        - name: registrations
          configMap:
            name: agentregistry-registrations
```

- [ ] **Step 3: Validate YAML syntax**

Run: `python3 -c "import yaml, sys; list(yaml.safe_load_all(open('agentregistry/k8s/registration-job.yaml')))"`
Expected: No output (valid YAML)

- [ ] **Step 4: Commit**

```bash
git add agentregistry/k8s/
git commit -m "Add AgentRegistry registration Job and ConfigMap"
```

---

### Task 4: Create AgentRegistry Config ArgoCD Application (Wave 9)

**Files:**
- Create: `argocd/apps/agentregistry-config.yaml`

**Context:** This ArgoCD Application deploys the ConfigMap and Job from `agentregistry/k8s/`. Wave 9 ensures AgentRegistry (wave 8) is deployed first. Points at `agentregistry/k8s` — NOT `config/` — to stay isolated from the wave 7 app.

- [ ] **Step 1: Create the ArgoCD Application manifest**

Create `argocd/apps/agentregistry-config.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: agentregistry-config
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "9"
spec:
  project: default
  source:
    repoURL: https://github.com/sebastianmaniak/k8s-goose.git
    targetRevision: main
    path: agentregistry/k8s
    directory:
      recurse: true
  destination:
    namespace: agentgateway-system
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

- [ ] **Step 2: Validate YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('argocd/apps/agentregistry-config.yaml'))"`
Expected: No output (valid YAML)

- [ ] **Step 3: Commit**

```bash
git add argocd/apps/agentregistry-config.yaml
git commit -m "Add AgentRegistry config ArgoCD application (wave 9)"
```

---

### Task 5: Final Validation and Push

**Files:** None new — validation only.

- [ ] **Step 1: Verify full file structure**

Run: `find argocd/apps agentregistry -type f | sort`

Expected:
```
agentregistry/k8s/registration-job.yaml
agentregistry/manifests/mcp-server-everything.yaml
agentregistry/manifests/mcp-website-fetcher.yaml
agentregistry/manifests/remote-servers.yaml
argocd/apps/agentgateway-config.yaml
argocd/apps/agentgateway-control-plane.yaml
argocd/apps/agentgateway-crds.yaml
argocd/apps/agentregistry-config.yaml
argocd/apps/agentregistry.yaml
argocd/apps/external-secrets.yaml
argocd/apps/gateway-api-crds.yaml
argocd/apps/solo-ui.yaml
argocd/apps/vault.yaml
```

- [ ] **Step 2: Validate all new YAML files parse cleanly**

Run: `for f in argocd/apps/agentregistry.yaml argocd/apps/agentregistry-config.yaml agentregistry/k8s/registration-job.yaml agentregistry/manifests/mcp-server-everything.yaml agentregistry/manifests/mcp-website-fetcher.yaml agentregistry/manifests/remote-servers.yaml; do echo "--- $f ---"; python3 -c "import yaml, sys; list(yaml.safe_load_all(open('$f')))" && echo "OK"; done`

Expected: All files print "OK"

- [ ] **Step 3: Verify wave ordering is correct**

Run: `grep -r "sync-wave" argocd/apps/ | sort -t'"' -k2 -n`

Expected output shows waves 1-9 in order, with agentregistry at 8 and agentregistry-config at 9.

- [ ] **Step 4: Verify no agentregistry files live under config/**

Run: `find config/agentregistry -type f 2>/dev/null | wc -l`

Expected: `0` (directory should not exist)

- [ ] **Step 5: Push to remote**

Run: `git push origin main`

ArgoCD will detect the new applications and begin syncing waves 8 and 9.
