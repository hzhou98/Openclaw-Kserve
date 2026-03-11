#!/usr/bin/env bash
# =============================================================================
# start.sh — Restart the cluster after stop.sh
# =============================================================================
#
# This script restarts services that were stopped by stop.sh.
#
# Two restart levels (matching stop.sh):
#
#   ./start.sh              Redeploy the model only (after stop.sh)
#                           System pool is already running. Just re-applies
#                           the InferenceService so the GPU node scales up
#                           and the model starts serving again.
#                           Time: ~5-10 min
#
#   ./start.sh --all        Restart nodes only (after stop.sh --all)
#                           Resizes system pool back to 1 and waits for
#                           system pods (Istio, KServe controller) to
#                           reschedule. Does NOT redeploy the model —
#                           run ./start.sh afterwards to bring the model up.
#                           Time: ~3-5 min
#
# Model selection (only for default mode, not --all):
#   ./start.sh --model qwen           Restart with Qwen instead of Llama
#
# If you used stop.sh --destroy, use deploy.sh instead (full redeploy).
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse arguments
MODE="gpu"
MODEL="llama"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)    MODE="all"; shift ;;
    --model)  MODEL="$2"; shift 2 ;;
    *)        echo "Unknown option: $1"; echo "Usage: ./start.sh [--all] [--model llama|qwen]"; exit 1 ;;
  esac
done

# Read cluster config
if [ -f "$ROOT_DIR/terraform/terraform.tfvars" ]; then
  PROJECT_ID=$(grep 'project_id' "$ROOT_DIR/terraform/terraform.tfvars" | cut -d'"' -f2)
  ZONE=$(grep 'zone' "$ROOT_DIR/terraform/terraform.tfvars" | cut -d'"' -f2)
  CLUSTER_NAME=$(grep 'cluster_name' "$ROOT_DIR/terraform/terraform.tfvars" | cut -d'"' -f2 || echo "openclaw-kserve")
else
  echo "ERROR: terraform/terraform.tfvars not found."
  exit 1
fi
CLUSTER_NAME="${CLUSTER_NAME:-openclaw-kserve}"

# Configure kubectl
echo "Configuring kubectl..."
gcloud container clusters get-credentials "$CLUSTER_NAME" \
  --zone "$ZONE" --project "$PROJECT_ID" --quiet

if [[ "$MODE" == "all" ]]; then
  # =========================================================================
  # --all: Scale nodes back up (reverse of stop.sh --all)
  # =========================================================================
  # Only resizes the system pool and waits for system pods. Does not redeploy
  # the model — run ./start.sh (without --all) afterwards to bring it up.
  # =========================================================================
  echo "============================================"
  echo "  Starting cluster nodes"
  echo "  Cluster: $CLUSTER_NAME ($ZONE)"
  echo "============================================"
  echo ""

  echo "=== Resizing system-pool to 1 node ==="
  gcloud container clusters resize "$CLUSTER_NAME" \
    --node-pool=system-pool \
    --num-nodes=1 \
    --zone "$ZONE" \
    --project "$PROJECT_ID" \
    --quiet

  # Wait for at least one node to be Ready
  echo "Waiting for system node to become Ready..."
  for i in $(seq 1 60); do
    READY_NODES=$(kubectl get nodes -l pool=system --no-headers 2>/dev/null | grep -c " Ready" || true)
    if [ "$READY_NODES" -ge 1 ]; then
      echo "System node is Ready."
      break
    fi
    if [ "$i" -eq 60 ]; then
      echo "WARNING: System node not ready after 5 minutes. Continuing anyway..."
    fi
    sleep 5
  done

  # Wait for critical system pods to reschedule
  echo "Waiting for system pods to reschedule..."
  kubectl wait --for=condition=Ready pod -l app=istiod -n istio-system --timeout=180s 2>/dev/null || true
  kubectl wait --for=condition=Ready pod -l control-plane=kserve-controller-manager -n kserve --timeout=180s 2>/dev/null || true
  echo "System pods are running."

  echo ""
  echo "============================================"
  echo "  Cluster nodes started!"
  echo "============================================"
  echo ""
  echo "System pool is running. To redeploy the model:"
  echo "  ./start.sh                  # Llama 3.2 3B (default)"
  echo "  ./start.sh --model qwen     # Qwen 3.5 2B"
  echo ""
  echo "Verify:"
  echo "  kubectl get nodes"
  echo "  kubectl get pods -A"

else
  # =========================================================================
  # Default: Redeploy the model (reverse of stop.sh)
  # =========================================================================
  # System pool is already running. Re-applies the InferenceService so the
  # GPU node scales up and the model starts serving again.
  # =========================================================================

  # Resolve model files
  case "$MODEL" in
    llama)
      ISVC_FILE="$ROOT_DIR/kserve/llama-inferenceservice.yaml"
      ISVC_NAME="llama-3-2b"
      MODEL_DISPLAY="Llama 3.2 3B Instruct"
      ;;
    qwen)
      ISVC_FILE="$ROOT_DIR/kserve/qwen-inferenceservice.yaml"
      ISVC_NAME="qwen-3-5-2b"
      MODEL_DISPLAY="Qwen 3.5 2B"
      ;;
    *)
      echo "ERROR: Unknown model '$MODEL'. Use 'llama' or 'qwen'."
      exit 1
      ;;
  esac

  echo "============================================"
  echo "  Starting model"
  echo "  Model: $MODEL_DISPLAY"
  echo "  Cluster: $CLUSTER_NAME ($ZONE)"
  echo "============================================"
  echo ""

  echo "=== Deploying $MODEL_DISPLAY ==="

  # Ensure the HF secret exists
  kubectl apply -f "$ROOT_DIR/kserve/hf-secret.yaml"

  # Apply the InferenceService (triggers GPU node scale-up)
  kubectl apply -f "$ISVC_FILE"

  echo "Waiting for InferenceService to become ready..."
  kubectl wait --for=condition=Ready "inferenceservice/$ISVC_NAME" -n kserve --timeout=600s || {
    echo "WARNING: InferenceService not ready within 10 minutes."
    echo "Check: kubectl get inferenceservice -n kserve"
    echo "       kubectl get pods -n kserve"
    echo "The model may still be loading — it should become ready shortly."
  }

  echo ""
  echo "============================================"
  echo "  Started!"
  echo "============================================"
  echo ""
  echo "Verify:"
  echo "  kubectl get inferenceservice -n kserve"
  echo "  kubectl get pods -n kserve"
  echo "  kubectl get pods -n openclaw"
  echo ""
  echo "Access OpenClaw:"
  echo "  kubectl port-forward -n openclaw svc/openclaw 18789:18789"
  echo "  Open http://localhost:18789"
fi
