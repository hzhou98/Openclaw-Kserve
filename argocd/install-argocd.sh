#!/usr/bin/env bash
# =============================================================================
# install-argocd.sh — Install ArgoCD on the GKE cluster
# =============================================================================
#
# ArgoCD is a GitOps continuous delivery tool for Kubernetes. It watches a
# Git repository for Kubernetes manifests / Helm charts and automatically
# syncs them to the cluster. Changes in Git → changes in the cluster.
#
# Why ArgoCD instead of running scripts manually?
#   - Declarative: The desired state is defined in Git, not in someone's head
#   - Self-healing: If someone manually changes a resource, ArgoCD reverts it
#   - Audit trail: Every change is a Git commit with author and timestamp
#   - Rollback: Revert a Git commit → ArgoCD rolls back the cluster
#   - Visibility: Web UI shows sync status, health, and diff for every app
#
# What this script does:
#   1. Installs ArgoCD via its official Helm chart
#   2. Waits for the server pod to become ready
#   3. Retrieves the initial admin password
#   4. Prints instructions for accessing the web UI and CLI
#
# After installation:
#   - Apply argocd/app-of-apps.yaml to bootstrap the entire stack
#   - OR apply individual app manifests from argocd/apps/
#
# Prerequisites:
#   - kubectl configured to point at the target cluster
#   - helm 3.0+ installed
# =============================================================================
set -euo pipefail

echo "=== Installing ArgoCD ==="

# -----------------------------------------------------------------------------
# Install ArgoCD via Helm
# -----------------------------------------------------------------------------
# The official argo/argo-cd chart installs:
#   - argocd-server: Web UI + API server
#   - argocd-repo-server: Clones Git repos and renders manifests
#   - argocd-application-controller: Watches Applications and syncs resources
#   - argocd-redis: Cache for repo/app state
#   - argocd-dex-server: OIDC authentication (optional)
#
# server.service.type=LoadBalancer creates an external IP for the web UI.
# For production, use an Ingress with TLS instead.
# -----------------------------------------------------------------------------
helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm repo update argo

helm install argocd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  --set 'server.service.type=LoadBalancer' \
  --wait --timeout 5m

echo ""
echo "=== ArgoCD installed ==="

# -----------------------------------------------------------------------------
# Retrieve initial admin password
# -----------------------------------------------------------------------------
# ArgoCD generates a random admin password at install time, stored as a
# Kubernetes secret. You'll need this to log into the web UI.
# Change it after first login with: argocd account update-password
# -----------------------------------------------------------------------------
echo ""
echo "--- Initial admin password ---"
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)
echo "Username: admin"
echo "Password: $ARGOCD_PASSWORD"

echo ""
echo "--- Access the ArgoCD UI ---"
echo ""
echo "Option 1: LoadBalancer (wait for external IP):"
echo "  kubectl get svc argocd-server -n argocd -w"
echo "  Open https://<EXTERNAL-IP>"
echo ""
echo "Option 2: Port-forward (immediate):"
echo "  kubectl port-forward svc/argocd-server -n argocd 8443:443"
echo "  Open https://localhost:8443"
echo ""
echo "--- ArgoCD CLI login ---"
echo "  argocd login localhost:8443 --username admin --password '$ARGOCD_PASSWORD' --insecure"
echo ""
echo "--- Next steps ---"
echo "  1. Update repoURL in argocd/app-of-apps.yaml to your Git repo"
echo "  2. Push this repo to Git"
echo "  3. kubectl apply -f argocd/app-of-apps.yaml"
echo "  4. Set secrets:"
echo "     argocd app set openclaw-model --helm-set hfToken=hf_xxx --helm-set gatewayToken=my-token"
echo "  5. Watch the ArgoCD UI as it syncs all applications"
