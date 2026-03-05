#!/usr/bin/env bash
# =============================================================================
# stop.sh — Stop the cluster to save costs
# =============================================================================
#
# This script stops GPU costs and optionally the entire cluster. Use it when
# you're done working and want to stop paying. Use start.sh to resume.
#
# Three stop levels:
#
#   ./stop.sh              Stop GPU only (delete InferenceService)
#                          Cost: ~$0.01/hr (system pool stays running)
#                          Restart: ~5-10 min (GPU node + model reload)
#
#   ./stop.sh --all        Stop GPU + resize system pool to 0 nodes
#                          Cost: ~$0.00/hr (cluster control plane is free)
#                          Restart: ~5-10 min (nodes scale back up)
#
#   ./stop.sh --destroy    Destroy the entire cluster via Terraform
#                          Cost: $0.00/hr (nothing exists)
#                          Restart: ~25-40 min (full redeploy with deploy.sh)
#
# How each level works:
#
#   GPU only (default):
#     Deletes the InferenceService resource. KServe removes the model pod,
#     and GKE autoscaler drains and terminates the GPU node within ~10 min.
#     The system pool (KServe controller, Istio, OpenClaw) stays running.
#     OpenClaw will show errors until the model is redeployed, but it won't
#     crash — it just can't reach the LLM endpoint.
#
#   --all:
#     Same as above, plus resizes the system node pool to 0 nodes. The GKE
#     control plane keeps running (free for zonal clusters), but there are
#     no worker nodes. All pods stop. This is the cheapest option that
#     preserves your cluster config, Helm releases, and Kubernetes state.
#     When you restart, pods reschedule automatically on new nodes.
#
#   --destroy:
#     Runs `terraform destroy` to delete the cluster entirely. This is the
#     cleanest stop but requires a full `deploy.sh` to restart. Persistent
#     volumes (OpenClaw data) are deleted. Use this if you won't need the
#     cluster for a while.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE="gpu"
if [[ "${1:-}" == "--all" ]]; then
  MODE="all"
elif [[ "${1:-}" == "--destroy" ]]; then
  MODE="destroy"
fi

# Read cluster config from terraform.tfvars
if [ -f "$ROOT_DIR/terraform/terraform.tfvars" ]; then
  PROJECT_ID=$(grep 'project_id' "$ROOT_DIR/terraform/terraform.tfvars" | cut -d'"' -f2)
  ZONE=$(grep 'zone' "$ROOT_DIR/terraform/terraform.tfvars" | cut -d'"' -f2)
  CLUSTER_NAME=$(grep 'cluster_name' "$ROOT_DIR/terraform/terraform.tfvars" | cut -d'"' -f2 || echo "openclaw-kserve")
else
  echo "ERROR: terraform/terraform.tfvars not found. Cannot determine cluster config."
  exit 1
fi
CLUSTER_NAME="${CLUSTER_NAME:-openclaw-kserve}"

echo "============================================"
echo "  Stopping OpenClaw + KServe"
echo "  Mode: $MODE"
echo "  Cluster: $CLUSTER_NAME ($ZONE)"
echo "============================================"
echo ""

if [[ "$MODE" == "destroy" ]]; then
  # -------------------------------------------------------------------------
  # Full destroy — delete the entire cluster
  # -------------------------------------------------------------------------
  echo "=== Destroying cluster via Terraform ==="
  echo "This will delete the cluster, all workloads, and all persistent data."
  read -p "Are you sure? (yes/no): " CONFIRM
  if [[ "$CONFIRM" != "yes" ]]; then
    echo "Aborted."
    exit 0
  fi
  cd "$ROOT_DIR/terraform"
  terraform destroy -auto-approve
  echo ""
  echo "Cluster destroyed. Run ./deploy.sh to redeploy."
  exit 0
fi

# Ensure kubectl is configured
echo "Configuring kubectl..."
gcloud container clusters get-credentials "$CLUSTER_NAME" \
  --zone "$ZONE" --project "$PROJECT_ID" --quiet 2>/dev/null || {
  echo "ERROR: Cannot connect to cluster. It may already be stopped or deleted."
  exit 1
}

# -------------------------------------------------------------------------
# Stop GPU — delete all InferenceServices
# -------------------------------------------------------------------------
echo "=== Stopping GPU workloads ==="

# Delete all InferenceServices in kserve namespace (handles both llama and qwen)
ISVCS=$(kubectl get inferenceservice -n kserve -o name 2>/dev/null || true)
if [ -n "$ISVCS" ]; then
  echo "Deleting InferenceServices:"
  echo "$ISVCS" | while read -r isvc; do
    echo "  $isvc"
    kubectl delete "$isvc" -n kserve --wait=false
  done
  echo "GPU node will scale to zero within ~10 minutes."
else
  echo "No InferenceServices found — GPU already stopped."
fi

if [[ "$MODE" == "all" ]]; then
  # -----------------------------------------------------------------------
  # Stop all nodes — resize pools to 0
  # -----------------------------------------------------------------------
  echo ""
  echo "=== Stopping all nodes ==="

  # Resize system pool to 0 (stops all system pods)
  echo "Resizing system-pool to 0 nodes..."
  gcloud container clusters resize "$CLUSTER_NAME" \
    --node-pool=system-pool \
    --num-nodes=0 \
    --zone "$ZONE" \
    --project "$PROJECT_ID" \
    --quiet

  # GPU pool should already be scaling to 0 from the InferenceService deletion,
  # but force it to be safe
  echo "Resizing gpu-pool to 0 nodes..."
  gcloud container clusters resize "$CLUSTER_NAME" \
    --node-pool=gpu-pool \
    --num-nodes=0 \
    --zone "$ZONE" \
    --project "$PROJECT_ID" \
    --quiet

  echo ""
  echo "All nodes stopped. Cluster control plane still running (free)."
fi

echo ""
echo "============================================"
echo "  Stopped!"
echo "============================================"
echo ""
if [[ "$MODE" == "gpu" ]]; then
  echo "GPU workloads removed. System pool still running (~\$0.01/hr)."
  echo "Restart with: ./start.sh"
elif [[ "$MODE" == "all" ]]; then
  echo "All nodes stopped. Only cluster control plane running (\$0.00/hr)."
  echo "Restart with: ./start.sh --all"
fi
