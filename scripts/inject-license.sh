#!/usr/bin/env bash
set -euo pipefail

# Injects the AGENTGATEWAY_LICENSE_KEY env var into the ArgoCD Application manifest.
# Run this before applying the app-of-apps if you haven't set it in ArgoCD directly.

if [[ -z "${AGENTGATEWAY_LICENSE_KEY:-}" ]]; then
  echo "ERROR: AGENTGATEWAY_LICENSE_KEY is not set"
  exit 1
fi

MANIFEST="argocd/apps/agentgateway-control-plane.yaml"

if [[ "$(uname)" == "Darwin" ]]; then
  sed -i '' "s|\\\$AGENTGATEWAY_LICENSE_KEY|${AGENTGATEWAY_LICENSE_KEY}|g" "$MANIFEST"
else
  sed -i "s|\\\$AGENTGATEWAY_LICENSE_KEY|${AGENTGATEWAY_LICENSE_KEY}|g" "$MANIFEST"
fi

echo "==> License key injected into $MANIFEST"
