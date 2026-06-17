# Langfuse + AgentGateway Trace Fan-Out Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run self-hosted Langfuse in the `maniak-goose` cluster and fan out AgentGateway OTLP traces to both the existing Solo telemetry collector and Langfuse, with all secrets sourced from Vault via External Secrets.

**Architecture:** A new OTel collector (`otel-fanout-collector`) in `agentgateway-system` receives the OTLP/gRPC AgentGateway already emits on :4317 and dual-exports — gRPC to the Solo collector (unchanged) and OTLP/HTTP (Basic auth) to Langfuse. Langfuse is installed by a new ArgoCD Application (Helm chart `langfuse/langfuse` v1.5.35) into a `langfuse` namespace. Credentials live in Vault and are synced by ESO into `langfuse-secrets` (ns `langfuse`) and `langfuse-otel-auth` (ns `agentgateway-system`).

**Tech Stack:** ArgoCD GitOps, Helm (langfuse-k8s v1.5.35), HashiCorp Vault (KV v2), External Secrets Operator, OpenTelemetry Collector (contrib 0.153.0), Gateway API / Solo EnterpriseAgentgatewayPolicy.

---

## Conventions for this plan

- **Repo root:** `/Users/sebbycorp/Library/CloudStorage/GoogleDrive-sebastian.maniak@solo.io/My Drive/Projects/k8s-goose`
- **kube context:** `maniak-goose`. Prefix live commands with `--context maniak-goose`.
- **Validation philosophy (infra/GitOps):** the "test" for each manifest is a local
  schema/template check (`helm template`, `kubectl apply --dry-run=client`) that must
  pass *before* commit. Live verification happens in the final task after push, since
  ArgoCD (automated + selfHeal) syncs on push.
- **Push strategy:** commit locally per task; **push once** in Task 8 so ArgoCD applies
  all waves coherently. Vault seeding (Task 1) is a live action done up front so secrets
  exist before the push.

## Exact chart field names (verified against chart v1.5.35)

| Purpose | Values path | Secret key it reads |
|---------|-------------|---------------------|
| Salt | `langfuse.salt.secretKeyRef.{name,key}` | `salt` |
| NextAuth secret | `langfuse.nextauth.secret.secretKeyRef.{name,key}` | `nextauth-secret` |
| Encryption key | `langfuse.encryptionKey.secretKeyRef.{name,key}` | `encryption-key` |
| Postgres | `postgresql.auth.existingSecret` + `secretKeys.userPasswordKey`/`adminPasswordKey` | `postgres-password` |
| Redis (valkey) | `redis.auth.existingSecret` + `existingSecretPasswordKey` | `redis-password` |
| ClickHouse | `clickhouse.auth.existingSecret` + `existingSecretKey` | `clickhouse-password` |
| MinIO root | `s3.auth.existingSecret` + `rootUserSecretKey`/`rootPasswordSecretKey` | `minio-root-user`, `minio-password` |
| App→S3 creds | `s3.accessKeyId.secretKeyRef` / `s3.secretAccessKey.secretKeyRef` | `minio-root-user`, `minio-password` |
| Init keys | `langfuse.additionalEnv[].valueFrom.secretKeyRef` | `init-public-key`, `init-secret-key`, `init-user-password` |

> ClickHouse subchart defaults to `replicaCount: 3` at `resourcesPreset: 2xlarge` — we
> override to `replicaCount: 1`, `resourcesPreset: small` for the lab. Chart uses
> `bitnamilegacy/*` images by default (public on Docker Hub — no change needed).

---

## File Structure

| File | Responsibility |
|------|----------------|
| `scripts/configure-vault.sh` (edit) | Generate + seed Langfuse secrets into Vault (idempotent) |
| `config/external-secrets/langfuse-external-secret.yaml` (new) | ESO: Vault `langfuse/config` → Secret `langfuse-secrets` in ns `langfuse` |
| `config/external-secrets/langfuse-otel-external-secret.yaml` (new) | ESO: Vault `langfuse/otel` → Secret `langfuse-otel-auth` in ns `agentgateway-system` |
| `config/otel-collector/configmap.yaml` (new) | Collector pipeline config |
| `config/otel-collector/deployment.yaml` (new) | Collector Deployment, `LANGFUSE_AUTH` from secret |
| `config/otel-collector/service.yaml` (new) | Collector Service `:4317` |
| `argocd/apps/langfuse.yaml` (new) | ArgoCD Application — Langfuse Helm chart, wave 6 |
| `config/policies/tracing.yaml` (edit) | Repoint `backendRef` to `otel-fanout-collector` |
| `README.md` (edit) | Component table, repo tree, trace-flow note |

---

## Task 1: Seed Langfuse secrets into Vault

**Files:**
- Modify: `scripts/configure-vault.sh` (append a Langfuse seeding block before the final summary `echo` block, after the xAI seeding at line ~73)

- [ ] **Step 1: Add the Langfuse seeding block**

Insert after the xAI key block (before the closing `echo ""` summary) in `scripts/configure-vault.sh`:

```bash
# ─── Seed Langfuse secrets (generate-if-absent; never rotates existing) ─────
echo "==> Seeding Langfuse secrets into Vault..."
if kubectl exec -n "$VAULT_NS" vault-0 -- vault kv get agentgateway/langfuse/config >/dev/null 2>&1; then
  echo "    agentgateway/langfuse/config already exists — skipping (delete the path to rotate)"
else
  LF_PK="pk-lf-$(uuidgen | tr 'A-Z' 'a-z')"
  LF_SK="sk-lf-$(uuidgen | tr 'A-Z' 'a-z')"
  LF_AUTH="$(printf '%s:%s' "$LF_PK" "$LF_SK" | base64 | tr -d '\n')"
  kubectl exec -n "$VAULT_NS" vault-0 -- vault kv put agentgateway/langfuse/config \
    salt="$(openssl rand -hex 16)" \
    encryption-key="$(openssl rand -hex 32)" \
    nextauth-secret="$(openssl rand -base64 32)" \
    postgres-password="$(openssl rand -hex 16)" \
    clickhouse-password="$(openssl rand -hex 16)" \
    redis-password="$(openssl rand -hex 16)" \
    minio-root-user="minio" \
    minio-password="$(openssl rand -hex 16)" \
    init-public-key="$LF_PK" \
    init-secret-key="$LF_SK" \
    init-user-password="$(openssl rand -base64 18 | tr -d '/+=' | head -c 20)"
  kubectl exec -n "$VAULT_NS" vault-0 -- vault kv put agentgateway/langfuse/otel auth="$LF_AUTH"
  echo "    Langfuse secrets stored (public key: $LF_PK)"
fi
```

Rationale: hex values for DB/redis/clickhouse/minio passwords avoid connection-string
encoding issues. `auth` is `base64(pk:sk)` computed in the same place as the keys so the
collector's Basic-auth always matches the init keys. Idempotent guard prevents rotating
secrets on re-run (which would orphan encrypted data).

- [ ] **Step 2: Lint the script**

Run: `bash -n scripts/configure-vault.sh`
Expected: no output (syntax OK).

- [ ] **Step 3: Run it against the cluster to seed Vault**

Run:
```bash
kubectl config use-context maniak-goose
bash scripts/configure-vault.sh
```
Expected: prints `Langfuse secrets stored (public key: pk-lf-...)` (or the "already exists — skipping" line on a re-run).

- [ ] **Step 4: Verify both Vault paths exist**

Run:
```bash
kubectl --context maniak-goose exec -n vault vault-0 -- vault kv get -format=json agentgateway/langfuse/config | jq -r '.data.data | keys[]'
kubectl --context maniak-goose exec -n vault vault-0 -- vault kv get -field=auth agentgateway/langfuse/otel | head -c 20; echo
```
Expected: first command lists the 11 keys (`clickhouse-password`, `encryption-key`, `init-public-key`, `init-secret-key`, `init-user-password`, `minio-password`, `minio-root-user`, `nextauth-secret`, `postgres-password`, `redis-password`, `salt`); second prints the start of a base64 string.

- [ ] **Step 5: Commit**

```bash
git add scripts/configure-vault.sh
git commit -m "feat(vault): seed Langfuse secrets (generate-if-absent)"
```

---

## Task 2: ExternalSecrets for Langfuse

**Files:**
- Create: `config/external-secrets/langfuse-external-secret.yaml`
- Create: `config/external-secrets/langfuse-otel-external-secret.yaml`

- [ ] **Step 1: Create the Langfuse chart secret (ns `langfuse`)**

`config/external-secrets/langfuse-external-secret.yaml`:
```yaml
# ExternalSecret — syncs all Langfuse chart secrets from Vault into the
# 'langfuse-secrets' Secret in the langfuse namespace. dataFrom.extract pulls
# every property of agentgateway/langfuse/config, so K8s secret keys match the
# Vault property names the Helm chart's secretKeyRef/existingSecret fields expect.
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: langfuse-secrets
  namespace: langfuse
spec:
  refreshInterval: "1h"
  secretStoreRef:
    name: vault
    kind: ClusterSecretStore
  target:
    name: langfuse-secrets
    creationPolicy: Owner
  dataFrom:
    - extract:
        key: langfuse/config
```

- [ ] **Step 2: Create the collector auth secret (ns `agentgateway-system`)**

`config/external-secrets/langfuse-otel-external-secret.yaml`:
```yaml
# ExternalSecret — syncs the Langfuse OTLP Basic-auth string from Vault into the
# 'langfuse-otel-auth' Secret consumed by the otel-fanout-collector.
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: langfuse-otel-auth
  namespace: agentgateway-system
spec:
  refreshInterval: "1h"
  secretStoreRef:
    name: vault
    kind: ClusterSecretStore
  target:
    name: langfuse-otel-auth
    creationPolicy: Owner
  data:
    - secretKey: LANGFUSE_AUTH
      remoteRef:
        key: langfuse/otel
        property: auth
```

- [ ] **Step 3: Validate YAML schema (client dry-run)**

Run:
```bash
kubectl --context maniak-goose apply --dry-run=client -f config/external-secrets/langfuse-external-secret.yaml -f config/external-secrets/langfuse-otel-external-secret.yaml
```
Expected: two lines ending `created (dry run)` (or `configured (dry run)`), no schema errors. (The CRD is already installed by the external-secrets app.)

- [ ] **Step 4: Commit**

```bash
git add config/external-secrets/langfuse-external-secret.yaml config/external-secrets/langfuse-otel-external-secret.yaml
git commit -m "feat(eso): add Langfuse + collector-auth ExternalSecrets"
```

---

## Task 3: otel-fanout-collector manifests

**Files:**
- Create: `config/otel-collector/configmap.yaml`
- Create: `config/otel-collector/deployment.yaml`
- Create: `config/otel-collector/service.yaml`

- [ ] **Step 1: Create the collector config**

`config/otel-collector/configmap.yaml`:
```yaml
# OpenTelemetry Collector that fans AgentGateway traces out to two backends:
#   1. solo-enterprise-telemetry-collector (gRPC) — keeps Solo UI tracing working
#   2. Langfuse (OTLP/HTTP + Basic auth) — new
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-fanout-collector
  namespace: agentgateway-system
data:
  config.yaml: |
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
    processors:
      batch: {}
    exporters:
      otlp/solo:
        endpoint: solo-enterprise-telemetry-collector:4317
        tls:
          insecure: true
      otlphttp/langfuse:
        endpoint: http://langfuse-web.langfuse:3000/api/public/otel
        headers:
          Authorization: "Basic ${env:LANGFUSE_AUTH}"
          x-langfuse-ingestion-version: "4"
    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [batch]
          exporters: [otlp/solo, otlphttp/langfuse]
```

- [ ] **Step 2: Create the Deployment**

`config/otel-collector/deployment.yaml`:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otel-fanout-collector
  namespace: agentgateway-system
  labels:
    app: otel-fanout-collector
spec:
  replicas: 1
  selector:
    matchLabels:
      app: otel-fanout-collector
  template:
    metadata:
      labels:
        app: otel-fanout-collector
    spec:
      containers:
        - name: otel-collector
          image: otel/opentelemetry-collector-contrib:0.153.0
          args: ["--config=/conf/config.yaml"]
          env:
            - name: LANGFUSE_AUTH
              valueFrom:
                secretKeyRef:
                  name: langfuse-otel-auth
                  key: LANGFUSE_AUTH
          ports:
            - name: otlp-grpc
              containerPort: 4317
          volumeMounts:
            - name: config
              mountPath: /conf
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              memory: 256Mi
      volumes:
        - name: config
          configMap:
            name: otel-fanout-collector
```

- [ ] **Step 3: Create the Service**

`config/otel-collector/service.yaml`:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: otel-fanout-collector
  namespace: agentgateway-system
  labels:
    app: otel-fanout-collector
spec:
  selector:
    app: otel-fanout-collector
  ports:
    - name: otlp-grpc
      port: 4317
      targetPort: 4317
      protocol: TCP
```

- [ ] **Step 4: Validate the three manifests**

Run:
```bash
kubectl --context maniak-goose apply --dry-run=client -f config/otel-collector/
```
Expected: three `(dry run)` lines, no errors.

- [ ] **Step 5: Sanity-check the collector config parses**

Run:
```bash
LANGFUSE_AUTH=dummy docker run --rm -i -v "$PWD/config/otel-collector/configmap.yaml":/tmp/cm.yaml \
  otel/opentelemetry-collector-contrib:0.153.0 --help >/dev/null 2>&1 && echo "image OK"
```
Expected: `image OK` (confirms the image tag is pullable). If `docker` is unavailable, skip — the config is validated live in Task 8.

- [ ] **Step 6: Commit**

```bash
git add config/otel-collector/
git commit -m "feat(otel): add trace fan-out collector (Solo + Langfuse)"
```

---

## Task 4: Langfuse ArgoCD Application

**Files:**
- Create: `argocd/apps/langfuse.yaml`

- [ ] **Step 1: Create the Application**

`argocd/apps/langfuse.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: langfuse
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "6"
spec:
  project: default
  source:
    chart: langfuse
    repoURL: https://langfuse.github.io/langfuse-k8s
    targetRevision: 1.5.35
    helm:
      valuesObject:
        langfuse:
          salt:
            secretKeyRef:
              name: langfuse-secrets
              key: salt
          encryptionKey:
            secretKeyRef:
              name: langfuse-secrets
              key: encryption-key
          nextauth:
            secret:
              secretKeyRef:
                name: langfuse-secrets
                key: nextauth-secret
          additionalEnv:
            - name: LANGFUSE_INIT_ORG_ID
              value: goose
            - name: LANGFUSE_INIT_ORG_NAME
              value: goose
            - name: LANGFUSE_INIT_PROJECT_ID
              value: agentgateway
            - name: LANGFUSE_INIT_PROJECT_NAME
              value: agentgateway
            - name: LANGFUSE_INIT_USER_EMAIL
              value: sebastian.maniak@solo.io
            - name: LANGFUSE_INIT_USER_NAME
              value: "Sebastian Maniak"
            - name: LANGFUSE_INIT_PROJECT_PUBLIC_KEY
              valueFrom:
                secretKeyRef:
                  name: langfuse-secrets
                  key: init-public-key
            - name: LANGFUSE_INIT_PROJECT_SECRET_KEY
              valueFrom:
                secretKeyRef:
                  name: langfuse-secrets
                  key: init-secret-key
            - name: LANGFUSE_INIT_USER_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: langfuse-secrets
                  key: init-user-password
        postgresql:
          auth:
            existingSecret: langfuse-secrets
            secretKeys:
              userPasswordKey: postgres-password
              adminPasswordKey: postgres-password
        redis:
          auth:
            existingSecret: langfuse-secrets
            existingSecretPasswordKey: redis-password
        clickhouse:
          replicaCount: 1
          resourcesPreset: small
          auth:
            existingSecret: langfuse-secrets
            existingSecretKey: clickhouse-password
        s3:
          accessKeyId:
            secretKeyRef:
              name: langfuse-secrets
              key: minio-root-user
          secretAccessKey:
            secretKeyRef:
              name: langfuse-secrets
              key: minio-password
          auth:
            existingSecret: langfuse-secrets
            rootUserSecretKey: minio-root-user
            rootPasswordSecretKey: minio-password
  destination:
    namespace: langfuse
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

- [ ] **Step 2: Validate the Application manifest schema**

Run:
```bash
kubectl --context maniak-goose apply --dry-run=client -f argocd/apps/langfuse.yaml
```
Expected: `application.argoproj.io/langfuse created (dry run)`, no errors.

- [ ] **Step 3: Render the chart with the same values to confirm no template errors**

Run:
```bash
cat > /tmp/lf-test-values.yaml <<'YAML'
langfuse:
  salt: {secretKeyRef: {name: langfuse-secrets, key: salt}}
  encryptionKey: {secretKeyRef: {name: langfuse-secrets, key: encryption-key}}
  nextauth: {secret: {secretKeyRef: {name: langfuse-secrets, key: nextauth-secret}}}
  additionalEnv:
    - {name: LANGFUSE_INIT_ORG_ID, value: goose}
    - {name: LANGFUSE_INIT_PROJECT_ID, value: agentgateway}
    - {name: LANGFUSE_INIT_USER_EMAIL, value: sebastian.maniak@solo.io}
    - {name: LANGFUSE_INIT_PROJECT_PUBLIC_KEY, valueFrom: {secretKeyRef: {name: langfuse-secrets, key: init-public-key}}}
    - {name: LANGFUSE_INIT_PROJECT_SECRET_KEY, valueFrom: {secretKeyRef: {name: langfuse-secrets, key: init-secret-key}}}
    - {name: LANGFUSE_INIT_USER_PASSWORD, valueFrom: {secretKeyRef: {name: langfuse-secrets, key: init-user-password}}}
postgresql: {auth: {existingSecret: langfuse-secrets, secretKeys: {userPasswordKey: postgres-password, adminPasswordKey: postgres-password}}}
redis: {auth: {existingSecret: langfuse-secrets, existingSecretPasswordKey: redis-password}}
clickhouse: {replicaCount: 1, resourcesPreset: small, auth: {existingSecret: langfuse-secrets, existingSecretKey: clickhouse-password}}
s3:
  accessKeyId: {secretKeyRef: {name: langfuse-secrets, key: minio-root-user}}
  secretAccessKey: {secretKeyRef: {name: langfuse-secrets, key: minio-password}}
  auth: {existingSecret: langfuse-secrets, rootUserSecretKey: minio-root-user, rootPasswordSecretKey: minio-password}
YAML
helm template langfuse langfuse/langfuse --version 1.5.35 -n langfuse -f /tmp/lf-test-values.yaml >/tmp/lf-rendered.yaml && echo "render OK lines=$(wc -l </tmp/lf-rendered.yaml)"
grep -c "LANGFUSE_INIT_PROJECT_PUBLIC_KEY" /tmp/lf-rendered.yaml
grep -c "name: langfuse-secrets" /tmp/lf-rendered.yaml
```
Expected: `render OK lines=<n>` with n in the thousands; both `grep -c` print a number ≥ 1 (init env + existingSecret refs are wired). If `helm repo add langfuse https://langfuse.github.io/langfuse-k8s` hasn't been run, run it first.

- [ ] **Step 4: Commit**

```bash
git add argocd/apps/langfuse.yaml
git commit -m "feat(argocd): add Langfuse Application (chart v1.5.35, wave 6)"
```

---

## Task 5: Repoint the tracing policy

**Files:**
- Modify: `config/policies/tracing.yaml:26` (the `backendRef.name`)

- [ ] **Step 1: Change the backendRef**

In `config/policies/tracing.yaml`, change:
```yaml
      backendRef:
        name: solo-enterprise-telemetry-collector
```
to:
```yaml
      backendRef:
        name: otel-fanout-collector
```
Leave `namespace`, `kind: Service`, `port: 4317`, and all four `targetRefs` unchanged. Also update the top comment block to read: `# Sends traces to the otel-fanout-collector, which fans out to the Solo collector and Langfuse.`

- [ ] **Step 2: Validate**

Run:
```bash
kubectl --context maniak-goose apply --dry-run=client -f config/policies/tracing.yaml
```
Expected: `enterpriseagentgatewaypolicy.../tracing configured (dry run)`, no errors.

- [ ] **Step 3: Commit**

```bash
git add config/policies/tracing.yaml
git commit -m "feat(tracing): route gateway traces through otel-fanout-collector"
```

---

## Task 6: Update README

**Files:**
- Modify: `README.md` (component table ~line 108-115, repo tree ~line 60-90)

- [ ] **Step 1: Add Langfuse + collector to the platform component table**

In the "Platform Layer" table (after the Solo UI row ~line 115), add:
```markdown
| **Langfuse** | `langfuse` (langfuse-k8s) | 1.5.35 | Self-hosted LLM observability — receives AgentGateway traces via OTel |
| **OTel fan-out collector** | plain YAML | contrib 0.153.0 | Dual-exports gateway traces to the Solo collector and Langfuse |
```

- [ ] **Step 2: Add the new files to the repo tree**

In the repo-tree block, under `argocd/apps/` add:
```
│       ├── langfuse.yaml             # Wave 6: Langfuse (langfuse-k8s v1.5.35)
```
and under `config/` add:
```
│   ├── otel-collector/              # Trace fan-out collector (Solo + Langfuse)
```
and under `config/external-secrets/` add the two new ExternalSecret lines:
```
│   │   ├── langfuse-external-secret.yaml      # ExternalSecret: Vault → langfuse-secrets (ns langfuse)
│   │   └── langfuse-otel-external-secret.yaml # ExternalSecret: Vault → langfuse-otel-auth
```

- [ ] **Step 3: Add a trace-flow note**

Under the tracing/observability description (or near the policies table), add:
```markdown
> **Trace flow:** AgentGateway → `otel-fanout-collector` (OTLP/gRPC :4317) →
> fans out to (1) `solo-enterprise-telemetry-collector` → Solo UI and
> (2) Langfuse (`langfuse-web:3000/api/public/otel`, OTLP/HTTP + Basic auth).
> Langfuse credentials come from Vault via External Secrets.
```

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: document Langfuse + trace fan-out in README"
```

---

## Task 7: Pre-push review

- [ ] **Step 1: Review the full diff**

Run:
```bash
git --no-pager log --oneline origin/main..HEAD
git --no-pager diff --stat origin/main..HEAD
```
Expected: 6 commits (Tasks 1-6), touching exactly the files in the File Structure table.

- [ ] **Step 2: Confirm no plaintext secret values are committed**

Run:
```bash
git --no-pager diff origin/main..HEAD | grep -iE "value: .*(pk-lf|sk-lf)|password:|salt:|encryptionKey:" | grep -v secretKeyRef | grep -v existingSecret || echo "CLEAN — no inline secret values"
```
Expected: `CLEAN — no inline secret values` (only secretKeyRef/existingSecret references appear, never literal secret values).

---

## Task 8: Push and verify end-to-end

- [ ] **Step 1: Push**

```bash
git push origin main
```
Expected: push succeeds to `github.com/sebbycorp/k8s-goose`.

- [ ] **Step 2: Watch ArgoCD apps converge**

Run (repeat until settled, ~3-8 min for first ClickHouse/Postgres boot):
```bash
kubectl --context maniak-goose get applications -n argocd
```
Expected: `langfuse` appears and reaches `Synced` / `Healthy` (transient `Progressing` during DB migrations is normal); `agentgateway-config` `Synced`.

- [ ] **Step 3: Confirm ESO synced both secrets**

Run:
```bash
kubectl --context maniak-goose get externalsecret -n langfuse langfuse-secrets
kubectl --context maniak-goose get externalsecret -n agentgateway-system langfuse-otel-auth
```
Expected: both show `STATUS: SecretSynced`, `READY: True`.

- [ ] **Step 4: Confirm Langfuse + collector pods are running**

Run:
```bash
kubectl --context maniak-goose get pods -n langfuse
kubectl --context maniak-goose get pods -n agentgateway-system -l app=otel-fanout-collector
```
Expected: `langfuse-web`, `langfuse-worker`, postgres, clickhouse, valkey/redis, minio pods `Running`; `otel-fanout-collector` `1/1 Running`.

- [ ] **Step 5: Confirm the collector authenticates to Langfuse (no 401)**

Run:
```bash
kubectl --context maniak-goose logs -n agentgateway-system -l app=otel-fanout-collector --tail=50
```
Expected: no repeated `401`/`403`/`Unauthorized` from the `otlphttp/langfuse` exporter. (Some "connection refused" lines are OK before Langfuse finishes booting; they should stop once `langfuse-web` is Ready.)

- [ ] **Step 6: Generate a trace through a gateway**

Run (use an existing working route; OpenAI shown):
```bash
kubectl --context maniak-goose port-forward deploy/agentgateway-proxy -n agentgateway-system 8080:80 &
sleep 3
curl -s "localhost:8080/openai/v1/chat/completions" -H content-type:application/json \
  -d '{"model":"","messages":[{"role":"user","content":"langfuse trace test"}]}' >/dev/null && echo "request sent"
```
Expected: `request sent`.

- [ ] **Step 7: Verify the trace in BOTH backends**

Run:
```bash
kubectl --context maniak-goose port-forward svc/langfuse-web -n langfuse 3000:3000 &
```
Then open `http://localhost:3000`, log in with `sebastian.maniak@solo.io` and the
`init-user-password` (retrieve it: `kubectl --context maniak-goose exec -n vault vault-0 -- vault kv get -field=init-user-password agentgateway/langfuse/config`),
and confirm a trace appears under project `agentgateway` → Tracing. Also confirm the
same trace still appears in the Solo UI (port-forward `svc/solo-enterprise-ui` as before).
Expected: the test request shows in **both** Langfuse and Solo UI.

- [ ] **Step 8: Final status report**

Summarize: ArgoCD app states, ESO sync status, both-backend trace confirmation. If any
step failed, capture the failing output rather than claiming success.

---

## Self-Review notes (for the implementer)

- **Spec coverage:** every spec component (Langfuse app, fan-out collector, tracing edit,
  Vault+ESO secrets, README) maps to Tasks 1-6; verification (spec §"Data flow") maps to Task 8.
- **Secret-key name consistency:** the Vault property names written in Task 1
  (`salt`, `encryption-key`, `nextauth-secret`, `postgres-password`, `redis-password`,
  `clickhouse-password`, `minio-root-user`, `minio-password`, `init-*`) are exactly the
  keys referenced by `secretKeyRef`/`existingSecret*` in Task 4 — verified against chart v1.5.35.
- **Known risk — ClickHouse footprint:** if the lab can't schedule ClickHouse even at
  `resourcesPreset: small`, drop to `nano` and/or set `clickhouse.resourcesPreset` lower;
  re-sync. Do not disable `clusterEnabled` (Langfuse requires keeper).
- **Known risk — first-boot ordering:** ESO must populate `langfuse-secrets` before the
  Langfuse pods start, else datastores fail auth. ArgoCD waves (Langfuse=6, config=7) plus
  selfHeal converge this automatically on retry; if pods CrashLoop on auth, delete the
  failing pods once `SecretSynced` is True.
```
