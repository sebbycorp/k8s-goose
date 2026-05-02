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

1. **Wave 8** deploys AgentRegistry server (v0.3.3) with bundled PostgreSQL into `agentgateway-system`
2. **Wave 9** deploys a one-shot Job that:
   - Waits for AgentRegistry to be healthy (`/healthz`)
   - Registers existing MCP servers via `PUT /v0/apply` REST API
3. External clients connect to the MCP endpoint (port 31313) and call `list_servers` / `get_server`

## Ports

| Port  | Protocol | Service Type | Purpose                  |
|-------|----------|-------------|--------------------------|
| 12121 | HTTP     | ClusterIP   | REST API (internal mgmt) |
| 21212 | gRPC     | ClusterIP   | gRPC API (internal)      |
| 31313 | MCP      | NodePort    | MCP discovery (external) |

## Registered MCP Servers

| Server | Transport | In-Cluster Endpoint |
|--------|-----------|---------------------|
| mcp-server-everything | streamable-http | `mcp-server-everything.agentgateway-system:3001` |
| mcp-website-fetcher | SSE | `mcp-website-fetcher.agentgateway-system:80` |

## Verification

```bash
# Check pods
kubectl get pods -n agentgateway-system | grep agentregistry

# Check registration job completed
kubectl get jobs -n agentgateway-system

# Check the NodePort service
kubectl get svc -n agentgateway-system agentregistry

# Query the registry API
curl http://<node-ip>:31313/v0/mcpservers
```

## Regenerating Helm Manifests

The server manifests are pre-rendered from the OCI Helm chart (ArgoCD v2.12 does not support OCI charts natively). To upgrade or change values:

```bash
helm template agentregistry \
  oci://ghcr.io/agentregistry-dev/agentregistry/charts/agentregistry \
  --version <NEW_VERSION> \
  --namespace agentgateway-system \
  --set service.type=NodePort \
  --set service.nodePorts.mcp=31313 \
  --set database.postgres.bundled.enabled=true \
  --set 'rbac.watchedNamespaces[0]=agentgateway-system' \
  --set config.jwtPrivateKey=$(openssl rand -hex 32) \
  --set config.enableAnonymousAuth=true \
  > agentregistry/server/agentregistry-manifests.yaml
```

Then commit and push — ArgoCD syncs automatically.

## Adding New MCP Servers

1. Add the server's Deployment + Service to `config/mcp-servers/` (existing GitOps pattern)
2. Add a registration entry to the ConfigMap in `agentregistry/k8s/registration-job.yaml`
3. Add a reference manifest to `agentregistry/manifests/`
4. Delete the existing Job to trigger re-registration:
   ```bash
   kubectl delete job agentregistry-register-mcpservers -n agentgateway-system
   ```
5. ArgoCD will recreate the Job with updated registrations
