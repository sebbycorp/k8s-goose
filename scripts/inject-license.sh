#!/usr/bin/env bash
set -euo pipefail

# Injects license keys into ArgoCD Application manifests.
# Supports both AgentGateway and Kagent Enterprise.
# Run this before applying the app-of-apps (or let ArgoCD pick up the committed placeholder).

AGENTGW_KEY="${AGENTGATEWAY_LICENSE_KEY:-}"
KAGENT_KEY="${KAGENT_ENTERPRISE_LICENSE_KEY:-}"

if [[ -z "$AGENTGW_KEY" && -z "$KAGENT_KEY" ]]; then
  echo "ERROR: At least one of AGENTGATEWAY_LICENSE_KEY or KAGENT_ENTERPRISE_LICENSE_KEY must be set"
  exit 1
fi

if [[ "$(uname)" == "Darwin" ]]; then
  SED_INPLACE=(sed -i '')
else
  SED_INPLACE=(sed -i)
fi

if [[ -n "$AGENTGW_KEY" ]]; then
  "${SED_INPLACE[@]}" "s|\\\$AGENTGATEWAY_LICENSE_KEY|${AGENTGW_KEY}|g" argocd/apps/agentgateway-control-plane.yaml
  echo "==> AgentGateway license injected"
fi

if [[ -n "$KAGENT_KEY" ]]; then
  "${SED_INPLACE[@]}" "s|\\\$KAGENT_ENTERPRISE_LICENSE_KEY|${KAGENT_KEY}|g" argocd/apps/kagent-enterprise.yaml
  echo "==> Kagent Enterprise license injected"
fi

echo "Done. Review changes and commit if needed."
