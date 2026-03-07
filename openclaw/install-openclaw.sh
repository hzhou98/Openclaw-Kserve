#!/usr/bin/env bash
# =============================================================================
# install-openclaw.sh — Deploy OpenClaw on Kubernetes
# =============================================================================
#
# This script installs OpenClaw, an open-source AI agent platform, into the
# "openclaw" namespace. OpenClaw acts as a gateway between messaging apps
# (or a web browser) and an LLM backend.
#
# What this script does:
#
#   1. Creates the "openclaw" namespace (idempotently)
#
#   2. Creates the openclaw-env-secret containing the Gateway Token.
#      The token is referenced in openclaw.json via ${OPENCLAW_GATEWAY_TOKEN}
#      env substitution (gateway.auth.token field). Access the UI by passing
#      the token in the URL: http://localhost:18789/?token=YOUR_TOKEN
#      If you don't provide one via OPENCLAW_GATEWAY_TOKEN env var, the
#      script generates a random 32-character hex string using openssl.
#
#   3. Installs OpenClaw via its official Helm chart, using the custom
#      values.yaml that configures the LLM backend to point at the KServe
#      vLLM endpoint instead of a cloud API.
#
# The --dry-run=client -o yaml | kubectl apply -f - pattern:
#   This is an idempotency trick. `kubectl create` fails if the resource
#   already exists. By piping through --dry-run=client (generates the YAML
#   without sending it to the server) and then `kubectl apply` (creates or
#   updates), the command succeeds whether the resource exists or not.
#   This makes the script safe to run multiple times.
#
# helm upgrade --install:
#   Another idempotency pattern. If the release "openclaw" doesn't exist,
#   it runs `helm install`. If it already exists, it runs `helm upgrade`.
#   This makes the script safe to re-run for configuration changes.
#
# Prerequisites:
#   - kubectl configured to point at the target cluster
#   - helm 3.0+ installed
#   - KServe InferenceService should be deployed (or deploying) so that
#     the LLM endpoint exists when OpenClaw tries to call it
# =============================================================================
set -euo pipefail

NAMESPACE="openclaw"
# Use the provided token, or generate a random one.
# The token is printed at the end — save it for device pairing.
GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-$(openssl rand -hex 16)}"

# Accept an optional --values flag to specify which values file to use.
# Defaults to values.yaml (Llama). Use values-qwen.yaml for Qwen.
# Usage: bash install-openclaw.sh --values values-qwen.yaml
VALUES_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --values) VALUES_FILE="$2"; shift 2 ;;
    *) shift ;;
  esac
done

echo "=== Installing OpenClaw ==="

# -----------------------------------------------------------------------------
# 1. Create namespace
# -----------------------------------------------------------------------------
# The "openclaw" namespace isolates OpenClaw resources from KServe and
# system components. Using a dedicated namespace makes it easy to see
# all OpenClaw-related pods, services, and secrets in one place, and
# simplifies cleanup (kubectl delete namespace openclaw removes everything).
# -----------------------------------------------------------------------------
echo "--- Creating namespace ---"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# -----------------------------------------------------------------------------
# 2. Create secret with Gateway Token
# -----------------------------------------------------------------------------
# OPENCLAW_GATEWAY_TOKEN authenticates access to the OpenClaw dashboard.
# The token is injected as an env var and referenced in openclaw.json via
# ${OPENCLAW_GATEWAY_TOKEN} substitution in the gateway.auth.token field.
# Access the UI by passing it in the URL: http://localhost:18789/?token=...
# The browser remembers the token after the first successful access.
# -----------------------------------------------------------------------------
echo "--- Creating secret ---"
SECRET_ARGS=(
  --namespace "$NAMESPACE"
  --from-literal=OPENCLAW_GATEWAY_TOKEN="$GATEWAY_TOKEN"
)
# Include OpenAI API key if provided (optional — enables OpenAI models in the UI)
if [ -n "${OPENAI_API_KEY:-}" ]; then
  SECRET_ARGS+=(--from-literal=OPENAI_API_KEY="$OPENAI_API_KEY")
  echo "  Including OPENAI_API_KEY in secret"
fi
kubectl create secret generic openclaw-env-secret \
  "${SECRET_ARGS[@]}" \
  --dry-run=client -o yaml | kubectl apply -f -

# -----------------------------------------------------------------------------
# 3. Helm install/upgrade
# -----------------------------------------------------------------------------
# Adds the OpenClaw Helm repository hosted on GitHub Pages, then installs
# (or upgrades) the chart with our custom values.yaml.
#
# SCRIPT_DIR resolution ensures the values.yaml path works regardless of
# where you run this script from (e.g., from the project root or from
# within the openclaw/ directory).
#
# --wait: Blocks until the OpenClaw pod is Running and Ready.
# --timeout 5m: Gives up after 5 minutes if the pod doesn't become ready
#   (e.g., image pull issues, resource constraints).
# -----------------------------------------------------------------------------
echo "--- Installing OpenClaw via Helm ---"
helm repo add openclaw https://serhanekicii.github.io/openclaw-helm --force-update
helm repo update openclaw

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Use the specified values file, or default to values.yaml
if [ -n "$VALUES_FILE" ]; then
  # If it's a relative path, resolve it relative to the openclaw/ directory
  if [[ "$VALUES_FILE" != /* ]]; then
    VALUES_FILE="$SCRIPT_DIR/$VALUES_FILE"
  fi
else
  VALUES_FILE="$SCRIPT_DIR/values.yaml"
fi
echo "Using values file: $VALUES_FILE"

helm upgrade --install openclaw openclaw/openclaw \
  --namespace "$NAMESPACE" \
  --values "$VALUES_FILE" \
  --wait --timeout 5m

echo ""
echo "=== OpenClaw installed ==="
echo ""
echo "Gateway token: $GATEWAY_TOKEN"
echo ""
echo "To access the UI:"
echo "  kubectl port-forward -n openclaw svc/openclaw 18789:18789"
echo "  Open http://localhost:18789/?token=$GATEWAY_TOKEN"
echo ""
echo "If you lose the token, retrieve it with:"
echo "  kubectl get secret openclaw-env-secret -n openclaw -o jsonpath='{.data.OPENCLAW_GATEWAY_TOKEN}' | base64 -d"
echo ""
echo "To approve device pairing:"
echo "  kubectl exec -n openclaw deployment/openclaw -c main -- node dist/index.js devices list"
echo "  kubectl exec -n openclaw deployment/openclaw -c main -- node dist/index.js devices approve <REQUEST_ID>"
