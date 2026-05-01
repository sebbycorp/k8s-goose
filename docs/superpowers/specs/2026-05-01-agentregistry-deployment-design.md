# AgentRegistry Deployment Design

## Context

The k8s-goose repo deploys Solo Enterprise AgentGateway v2.3.x on Kubernetes via ArgoCD app-of-apps with sync waves 1-7. Two MCP servers run in `agentgateway-system`: `mcp-server-everything` (streamable-http on port 3001) and `mcp-website-fetcher` (SSE on port 80). AgentGateway handles routing, auth, and tracing. What's missing is a discovery/catalog layer.

## Goal

Deploy AgentRegistry as a full registry (discovery + deployment management) into the existing cluster, fitting the GitOps pattern. External tools (Claude Desktop, Cursor, agents) should be able to query AgentRegistry's MCP endpoint to discover available MCP servers.

## Approach

Helm chart via ArgoCD, same namespace (`agentgateway-system`), with a registration Job for MCP server catalog entries.

## Architecture

### Wave 8: AgentRegistry Helm Chart

New ArgoCD Application `argocd/apps/agentregistry.yaml`:

- Chart: `ghcr.io/agentregistry-dev/agentregistry` (OCI)
- Namespace: `agentgateway-system`
- Ports: HTTP (12121 ClusterIP), gRPC (21212 ClusterIP), MCP (31313 NodePort)
- Bundled PostgreSQL enabled (dev-grade, 5Gi PVC)
- Sync wave 8 (after all existing infra)

### Wave 9: Registration Job

New ArgoCD Application `argocd/apps/agentregistry-config.yaml`:

- Deploys a Kubernetes Job from `config/agentregistry/`
- Job waits for AgentRegistry health, then POSTs registration manifests to `http://agentregistry:12121/v0/apply`
- Registers both MCPServer (catalog entries) and RemoteMCPServer (in-cluster endpoints)

### Registration Manifests

Stored in `config/agentregistry/`:

**MCPServer entries** (catalog metadata):
- `mcp-server-everything` v1.0.0 — demo server, streamable-http transport
- `mcp-website-fetcher` v1.0.0 — website content extraction, SSE transport

**RemoteMCPServer entries** (live endpoints):
- `mcp-server-everything-remote` — `http://mcp-server-everything.agentgateway-system.svc.cluster.local:3001`
- `mcp-website-fetcher-remote` — `http://mcp-website-fetcher.agentgateway-system.svc.cluster.local:80`

### Discovery Flow

1. AgentRegistry runs its own MCP server on port 31313
2. External clients connect to `172.16.10.149:<NodePort>` (AgentRegistry MCP)
3. Clients call `list_servers` / `get_server` to discover available servers
4. Clients connect to discovered servers via AgentGateway `/mcp` route or directly in-cluster

## File Changes

All additive — no existing files modified.

```
argocd/apps/
  agentregistry.yaml              # NEW - Wave 8 Helm chart
  agentregistry-config.yaml       # NEW - Wave 9 registration

config/agentregistry/
  mcp-server-everything.yaml      # NEW - MCPServer registration
  mcp-website-fetcher.yaml        # NEW - MCPServer registration
  remote-servers.yaml             # NEW - RemoteMCPServer endpoints
  registration-job.yaml           # NEW - Job to POST registrations
```

## Exposure

| Port  | Protocol | Service Type | Purpose                     |
|-------|----------|--------------|-----------------------------|
| 12121 | HTTP     | ClusterIP    | REST API (internal mgmt)    |
| 21212 | gRPC     | ClusterIP    | gRPC API (internal)         |
| 31313 | MCP      | NodePort     | MCP discovery (external)    |

## Constraints

- Bundled PostgreSQL is dev-grade only — acceptable for this demo/dev cluster
- Registration manifests are AgentRegistry API objects, not K8s CRDs — must be applied via REST API, hence the Job
- Job must wait for AgentRegistry readiness before POSTing
