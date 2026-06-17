# Langfuse + AgentGateway Trace Fan-Out — Design

**Date:** 2026-06-16
**Status:** Approved for planning
**Cluster:** `maniak-goose` (Talos/Omni lab)
**Repo:** `github.com/sebbycorp/k8s-goose` (ArgoCD GitOps)

## Goal

Run self-hosted Langfuse in this cluster and send AgentGateway traces to it **via
OpenTelemetry**, without breaking the existing Solo UI tracing. Both observability
backends receive the same traces.

## Decisions (locked)

| Decision | Choice |
|----------|--------|
| Trace routing | **Fan out to both** — a new OTel collector dual-exports to the Solo collector and to Langfuse |
| Langfuse hosting | Self-hosted on-cluster via official Helm chart `langfuse/langfuse` v1.5.35 (appVersion 3.185.0) |
| Credential bootstrap | **Headless auto-init** (`LANGFUSE_INIT_*`) with pre-generated keys |
| Secret storage | **HashiCorp Vault + External Secrets Operator** — same flow as the OpenAI/xAI keys; nothing secret committed to Git |
| Delivery | GitOps — new ArgoCD Application + plain config YAML |

## Architecture

```
                         ┌─▶ solo-enterprise-telemetry-collector:4317 (OTLP/gRPC) ─▶ ClickHouse ─▶ Solo UI
AgentGateway ──OTLP/gRPC──▶ otel-fanout-collector  (ns: agentgateway-system)
  (tracing policy :4317)    └─▶ langfuse-web.langfuse:3000/api/public/otel (OTLP/HTTP + Basic auth) ─▶ Langfuse UI
```

- AgentGateway already emits OTLP/gRPC on 4317. We do **not** change what it emits.
- The only edit to existing config is repointing the tracing policy `backendRef` from
  `solo-enterprise-telemetry-collector` to `otel-fanout-collector`.
- Langfuse accepts **OTLP/HTTP only** (no gRPC), so the fan-out collector translates
  gRPC-in → HTTP-out for the Langfuse leg while keeping gRPC-out for the Solo leg.

## Components

### 1. Langfuse (Helm, new namespace `langfuse`)
- New file: `argocd/apps/langfuse.yaml` — ArgoCD Application, **sync-wave 6**.
- `repoURL: https://langfuse.github.io/langfuse-k8s`, `chart: langfuse`, `targetRevision: 1.5.35`.
- `CreateNamespace=true`, destination namespace `langfuse`.
- Bundled subcomponents (chart defaults, single-replica for lab):
  PostgreSQL, ClickHouse, Redis, MinIO (S3 blob storage).
- **No secret values inline.** Helm values reference the ESO-materialized
  `langfuse-secrets` Secret (§4) via `secretKeyRef` / subchart `auth.existingSecret`:
  - `langfuse.salt.secretKeyRef`, `langfuse.nextauth.secret.secretKeyRef`,
    `langfuse.encryptionKey` (chart's secretKeyRef form)
  - `postgresql.auth.existingSecret`, `clickhouse.auth.existingSecret`,
    `redis.auth.existingSecret`, `s3.auth.existingSecret` (exact key names per
    each subchart's values — confirmed during implementation against chart v1.5.35)
  - `LANGFUSE_INIT_*` via `langfuse.additionalEnv` with `valueFrom.secretKeyRef`
    (`init-public-key`, `init-secret-key`, `init-user-password`); non-secret init
    fields (org/project/user ids + names) as plain `additionalEnv` values.
- Lab sizing: ClickHouse/Postgres/Redis/MinIO `replicaCount: 1`, modest resource
  requests. ClickHouse keeper kept minimal/single.

> **Implementation risk:** the bundled Bitnami-style subcharts each expose
> `auth.existingSecret` with their own expected key names (e.g. `postgres-password`,
> `admin-password`). The plan's first step verifies these against chart v1.5.35's
> `values.yaml` before wiring, so the materialized Secret uses the right keys.

### 2. otel-fanout-collector (plain YAML, ns `agentgateway-system`)
- New dir: `config/otel-collector/` applied by the existing `agentgateway-config`
  app (wave 7, recurse). Files: `configmap.yaml`, `deployment.yaml`, `service.yaml`.
  (Auth Secret is materialized by ESO — see §4 — not committed here.)
- Image: `otel/opentelemetry-collector-contrib:0.153.0` (already in-cluster → no new pull).
- Service `otel-fanout-collector` exposes `4317` (gRPC).
- Collector pipeline:
  - **receivers.otlp.protocols.grpc** on `0.0.0.0:4317`
  - **exporters.otlp/solo** → `solo-enterprise-telemetry-collector:4317` (`tls.insecure: true`)
  - **exporters.otlphttp/langfuse** → `http://langfuse-web.langfuse:3000/api/public/otel`
    with headers `Authorization: Basic ${env:LANGFUSE_AUTH}` and
    `x-langfuse-ingestion-version: "4"`
  - **service.pipelines.traces**: receivers `[otlp]`, exporters `[otlp/solo, otlphttp/langfuse]`
- `LANGFUSE_AUTH` injected via `env.valueFrom.secretKeyRef` from the ESO-materialized
  `langfuse-otel-auth` Secret (§4). No plain Secret committed.

### 3. tracing policy edit
- `config/policies/tracing.yaml`: change the single `backendRef.name` from
  `solo-enterprise-telemetry-collector` to `otel-fanout-collector`. Port stays `4317`,
  `kind: Service`. All four gateway targetRefs unchanged.

### 4. Secrets via Vault + External Secrets Operator

Nothing secret is committed to Git. Values are seeded into Vault and synced into the
cluster by ESO, exactly like the existing `llm-keys/openai` / `llm-keys/xai` flow.

**Vault (KV v2 mount `agentgateway/`, via `scripts/configure-vault.sh`):**
- `agentgateway/langfuse/config` — properties: `salt`, `encryption-key`,
  `nextauth-secret`, `postgres-password`, `clickhouse-password`, `redis-password`,
  `minio-password`, `init-public-key`, `init-secret-key`, `init-user-password`.
- `agentgateway/langfuse/otel` — property: `auth` (= `base64(pk:sk)`).

The `configure-vault.sh` script gains a Langfuse seeding block (values read from env
vars with the generated defaults below), plus `vault kv put` for both paths. The
existing `agentgateway-readonly` policy already covers `agentgateway/data/*`, so no
policy change is needed.

**ExternalSecrets (`config/external-secrets/`, `secretStoreRef: vault` / ClusterSecretStore):**
- `langfuse-secrets` → `metadata.namespace: langfuse`, target Secret `langfuse-secrets`,
  one `data` entry per property of `agentgateway/langfuse/config`. The Langfuse chart's
  `secretKeyRef` / `existingSecret` fields point at this Secret.
- `langfuse-otel-auth` → `metadata.namespace: agentgateway-system`, target Secret
  `langfuse-otel-auth`, key `LANGFUSE_AUTH` ← `agentgateway/langfuse/otel` property `auth`.

> The `langfuse` namespace must exist before its ExternalSecret syncs — guaranteed by
> ordering: Langfuse app is wave 6 (`CreateNamespace=true`), config app is wave 7.
> Both ExternalSecrets live in `config/` (applied by the wave-7 `agentgateway-config`
> app under the `default` AppProject, which permits cross-namespace resources).

**Secret values are generated at runtime by `scripts/configure-vault.sh`** and stored
only in Vault (`agentgateway/langfuse/config` and `.../otel`). They are deliberately
NOT recorded here or in any manifest. The Vault properties are:
`salt`, `encryption-key`, `nextauth-secret`, `postgres-password`, `clickhouse-password`,
`redis-password`, `minio-root-user` (= `minio`), `minio-password`, `init-public-key`
(`pk-lf-…`), `init-secret-key` (`sk-lf-…`), `init-user-password`; and for the collector,
`auth` = `base64(init-public-key:init-secret-key)`.

To read the generated values (e.g. the login password):
`kubectl exec -n vault vault-0 -- vault kv get -field=init-user-password agentgateway/langfuse/config`

Init identity (non-secret, plain `additionalEnv`): `LANGFUSE_INIT_ORG_ID=goose`,
`LANGFUSE_INIT_ORG_NAME=goose`, `LANGFUSE_INIT_PROJECT_ID=agentgateway`,
`LANGFUSE_INIT_PROJECT_NAME=agentgateway`,
`LANGFUSE_INIT_USER_EMAIL=sebastian.maniak@solo.io`,
`LANGFUSE_INIT_USER_NAME=Sebastian Maniak`.

> These are lab values recorded in this private design doc for reference; the running
> system reads them from Vault, not from Git.

## Data flow / verification

0. Run `scripts/configure-vault.sh` (with the Langfuse block) to seed
   `agentgateway/langfuse/config` + `agentgateway/langfuse/otel`; confirm ESO
   materializes `langfuse-secrets` (ns `langfuse`) and `langfuse-otel-auth`
   (ns `agentgateway-system`) — both ExternalSecrets report `SecretSynced`.
1. Port-forward Langfuse web (`svc/langfuse-web -n langfuse 3000:3000`), log in with
   the init user, confirm org `goose` / project `agentgateway` exist.
2. Send a request through a gateway (e.g. `/openai/...` or the MCP route).
3. Confirm the trace appears in **both** Solo UI and Langfuse → Traces.
4. `kubectl logs` on the fan-out collector shows both exporters succeeding (no auth 401).

## Error handling

- Langfuse unavailable: collector retries/queues then drops; Solo leg unaffected (independent exporters).
- Auth mismatch (401 from Langfuse): re-derive `LANGFUSE_AUTH` from the init keys; they must stay in sync.
- ClickHouse/Postgres slow first boot: Langfuse web `Progressing` until migrations finish; init runs once DB is ready.

## Out of scope

- Ingress/TLS for the Langfuse UI (access via port-forward, as with Solo UI).
- Sampling changes — keep `randomSampling: "true"` (capture all).
- Production hardening (HA datastores, backups, retention tuning).

## New/changed files

```
argocd/apps/langfuse.yaml                          (new — Application, wave 6)
config/otel-collector/configmap.yaml               (new — collector pipeline)
config/otel-collector/deployment.yaml              (new — env from langfuse-otel-auth)
config/otel-collector/service.yaml                 (new — :4317)
config/external-secrets/langfuse-external-secret.yaml      (new — ESO → langfuse-secrets, ns langfuse)
config/external-secrets/langfuse-otel-external-secret.yaml (new — ESO → langfuse-otel-auth, ns agentgateway-system)
config/policies/tracing.yaml                       (edit — backendRef → otel-fanout-collector)
scripts/configure-vault.sh                         (edit — seed agentgateway/langfuse/* )
README.md                                          (edit — component table, repo tree, trace-flow note)
```

No `Secret` manifests are committed — ESO materializes both Secrets from Vault.
