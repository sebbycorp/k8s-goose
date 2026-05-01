#!/usr/bin/env bash
set -euo pipefail

# ─── Install ArgoCD ──────────────────────────────────────────────────
echo "==> Installing ArgoCD..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
until kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.12.3/manifests/install.yaml > /dev/null 2>&1; do
  sleep 2
done

echo "==> Waiting for ArgoCD components..."
for deploy in argocd-applicationset-controller argocd-dex-server argocd-notifications-controller argocd-redis argocd-repo-server argocd-server; do
  kubectl -n argocd rollout status deploy/"$deploy" --timeout=120s
done

# ─── Set admin password to 'gateway' ────────────────────────────────
echo "==> Setting ArgoCD admin password to 'gateway'..."
kubectl -n argocd patch secret argocd-secret \
  -p "{\"stringData\": {\"admin.password\": \"\$2y\$10\$f6GlB5V/8OzCduEDEgBU.ugVn4vzxgT7cq7vuCebZAKoADaNve9Ve\",\"admin.passwordMtime\": \"$(date +%FT%T%Z)\"}}"

echo "==> ArgoCD installed. Admin password: gateway"
echo "    Port-forward: kubectl port-forward svc/argocd-server -n argocd 8443:443"
echo "    Login:        argocd login localhost:8443 --username admin --password gateway --insecure"
