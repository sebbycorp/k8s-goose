#!/usr/bin/env bash
set -euo pipefail

# Configures Vault with:
#   - KV v2 secrets engine at agentgateway/
#   - Kubernetes auth method
#   - Policy for ESO to read secrets
#   - Seeds LLM API keys from environment variables

VAULT_NS="vault"
AGW_NS="agentgateway-system"
ESO_NS="external-secrets"

echo "==> Waiting for Vault pod to be ready..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=vault -n "$VAULT_NS" --timeout=120s

echo "==> Enabling KV v2 secrets engine at agentgateway/..."
kubectl exec -n "$VAULT_NS" vault-0 -- vault secrets enable -path=agentgateway kv-v2 2>/dev/null || echo "    (already enabled)"

echo "==> Writing Vault policy for ESO..."
kubectl exec -n "$VAULT_NS" vault-0 -- sh -c 'vault policy write agentgateway-readonly - <<POLICY
path "agentgateway/data/*" {
  capabilities = ["read"]
}
path "agentgateway/metadata/*" {
  capabilities = ["read", "list"]
}
POLICY'

echo "==> Enabling Kubernetes auth..."
kubectl exec -n "$VAULT_NS" vault-0 -- vault auth enable kubernetes 2>/dev/null || echo "    (already enabled)"

echo "==> Configuring Kubernetes auth backend..."
kubectl exec -n "$VAULT_NS" vault-0 -- sh -c 'vault write auth/kubernetes/config \
  kubernetes_host="https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT"'

echo "==> Creating Vault role for ESO service account..."
kubectl exec -n "$VAULT_NS" vault-0 -- vault write auth/kubernetes/role/external-secrets \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces="$ESO_NS" \
  policies=agentgateway-readonly \
  ttl=1h

# ─── Seed secrets from environment variables ─────────────────────
echo "==> Seeding LLM API keys into Vault..."

if [[ -n "${OPENAI_API_KEY:-}" ]]; then
  kubectl exec -n "$VAULT_NS" vault-0 -- vault kv put agentgateway/llm-keys/openai Authorization="$OPENAI_API_KEY"
  echo "    OpenAI key stored"
else
  echo "    OPENAI_API_KEY not set — skipping (set it and re-run to add)"
fi

if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  kubectl exec -n "$VAULT_NS" vault-0 -- vault kv put agentgateway/llm-keys/anthropic Authorization="$ANTHROPIC_API_KEY"
  echo "    Anthropic key stored"
else
  echo "    ANTHROPIC_API_KEY not set — skipping"
fi

if [[ -n "${AZURE_OPENAI_API_KEY:-}" ]]; then
  kubectl exec -n "$VAULT_NS" vault-0 -- vault kv put agentgateway/llm-keys/azure-openai Authorization="$AZURE_OPENAI_API_KEY"
  echo "    Azure OpenAI key stored"
else
  echo "    AZURE_OPENAI_API_KEY not set — skipping"
fi

if [[ -n "${XAI_API_KEY:-}" ]]; then
  kubectl exec -n "$VAULT_NS" vault-0 -- vault kv put agentgateway/llm-keys/xai Authorization="$XAI_API_KEY"
  echo "    xAI key stored"
else
  echo "    XAI_API_KEY not set — skipping"
fi

echo ""
echo "==> Vault configured. Secrets stored at agentgateway/llm-keys/<provider>"
echo "    To add a key later:"
echo "    kubectl exec -n vault vault-0 -- vault kv put agentgateway/llm-keys/<provider> Authorization=<key>"
echo ""
echo "    To list all keys:"
echo "    kubectl exec -n vault vault-0 -- vault kv list agentgateway/llm-keys"
