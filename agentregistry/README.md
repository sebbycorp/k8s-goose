# AgentRegistry Deployment

AgentRegistry provides a discovery and management layer for MCP servers in this cluster. External tools (Claude Desktop, Cursor, agents) can query AgentRegistry's MCP endpoint to find available servers.

## Architecture

```
ArgoCD Wave 8: agentregistry (server + PostgreSQL)
ArgoCD Wave 9: agentregistry-config (registration Job)

agentregistry/
  server/                    # Pre-rendered Helm chart manifests (wave 8)
    agentregistry-manifests.yaml
  k8s/                       # Registration Job + ConfigMap (wave 9)
    registration-job.yaml
  manifests/                 # Reference copies of registration data (not deployed)
    mcp-server-everything.yaml
    mcp-website-fetcher.yaml
    remote-servers.yaml
```

## How It Works

1. **Wave 8** deploys AgentRegistry server (v0.3.3) with bundled PostgreSQL (pgvector) into `agentgateway-system`
2. **Wave 9** deploys a one-shot Job that:
   - Waits for AgentRegistry to be healthy via `GET /v0/health`
   - Registers existing MCP servers via `POST /v0/servers` (JSON, server.json schema)
3. External clients connect to the MCP endpoint (port 31313) and call `list_servers` / `get_server`

## Key Details

- **Server image:** `ghcr.io/agentregistry-dev/agentregistry/server:v0.3.3` (note `v` prefix on tags)
- **PostgreSQL image:** `pgvector/pgvector:pg17` (required for vector extension)
- **PostgreSQL storage:** `emptyDir` (data lost on pod restart — acceptable for dev)
- **ArgoCD:** Pre-rendered manifests because ArgoCD v2.12 cannot pull OCI Helm charts natively
- **Registration API:** `POST /v0/servers` with `application/json` using the [server.json schema](https://static.modelcontextprotocol.io/schemas/2025-10-17/server.schema.json)
- **Server naming:** Reverse-DNS format with `/` separator (e.g. `agentgateway.dev/mcp-server-everything`)

## Ports

| Port  | Protocol | Service Type | Purpose                  |
|-------|----------|-------------|--------------------------|
| 12121 | HTTP     | NodePort (32202) | REST API, Web UI    |
| 21212 | gRPC     | NodePort (30484) | gRPC API             |
| 31313 | MCP      | NodePort (31313) | MCP discovery        |

## Registered MCP Servers

| Server | Description | Version |
|--------|-------------|---------|
| `agentgateway.dev/mcp-server-everything` | Demo MCP server with sample tools, resources, and prompts | 1.0.0 |
| `agentgateway.dev/mcp-website-fetcher` | Fetches and extracts content from websites via MCP | 1.0.0 |

## Verification

```bash
# Check pods are running
kubectl get pods -n agentgateway-system | grep agentregistry

# Check registration job completed
kubectl get jobs -n agentgateway-system

# Check the service and NodePorts
kubectl get svc -n agentgateway-system agentregistry

# Query registered servers via REST API
curl http://172.16.10.149:32202/v0/servers

# Check health
curl http://172.16.10.149:32202/v0/health

# Access the Web UI
open http://172.16.10.149:32202

# Access API docs
open http://172.16.10.149:32202/docs
```

## Regenerating Helm Manifests

The server manifests are pre-rendered from the OCI Helm chart (ArgoCD v2.12 does not support OCI charts natively). To upgrade or change values:

```bash
helm template agentregistry \
  oci://ghcr.io/agentregistry-dev/agentregistry/charts/agentregistry \
  --version <NEW_CHART_VERSION> \
  --namespace agentgateway-system \
  --set service.type=NodePort \
  --set service.nodePorts.mcp=31313 \
  --set database.postgres.bundled.enabled=true \
  --set 'rbac.watchedNamespaces[0]=agentgateway-system' \
  --set config.jwtPrivateKey=$(openssl rand -hex 32) \
  --set config.enableAnonymousAuth=true \
  > agentregistry/server/agentregistry-manifests.yaml
```

After rendering, apply these manual fixes:

1. **PostgreSQL image** — replace `docker.io/library/postgres:18` with `pgvector/pgvector:pg17`
2. **Server image tag** — ensure it uses the `v` prefix (e.g. `v0.3.3` not `0.2.1`)
3. **PVC to emptyDir** — remove the PersistentVolumeClaim and replace `persistentVolumeClaim` volume with `emptyDir: {}`

Then commit and push — ArgoCD syncs automatically.

## Adding New MCP Servers

1. Add the server's Deployment + Service to `config/mcp-servers/` (existing GitOps pattern)
2. Add a JSON registration entry to the ConfigMap in `agentregistry/k8s/registration-job.yaml`:
   ```json
   {
     "$schema": "https://static.modelcontextprotocol.io/schemas/2025-10-17/server.schema.json",
     "name": "agentgateway.dev/<server-name>",
     "description": "<description>",
     "version": "1.0.0"
   }
   ```
3. Add a reference manifest to `agentregistry/manifests/`
4. Commit, push, then delete the existing Job to trigger re-registration:
   ```bash
   kubectl delete job agentregistry-register-mcpservers -n agentgateway-system
   ```
5. ArgoCD will recreate the Job with updated registrations

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| PostgreSQL pod Pending | Longhorn PVC provisioning issue | Already using emptyDir — shouldn't happen |
| Server CrashLoopBackOff with "vector not available" | Wrong PostgreSQL image | Use `pgvector/pgvector:pg17` |
| Server ImagePullBackOff | Wrong image tag | Tags use `v` prefix: `v0.3.3` not `0.3.3` |
| Registration Job stuck in Init | Health endpoint wrong | Use `/v0/health` not `/healthz` |
| Registration returns 404 | Wrong API endpoint | Use `POST /v0/servers` with JSON, not `PUT /v0/apply` with YAML |
| Registration returns 400 domain mismatch | Server name doesn't match URL domain | Use `agentgateway.dev/` prefix or register without remotes |
