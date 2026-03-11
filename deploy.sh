#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Master deployment script for OpenClaw + KServe on GKE
# =============================================================================
#
# This script orchestrates the complete deployment in four sequential steps:
#
#   Step 1: Terraform → Provision GKE cluster with system + GPU node pools
#   Step 2: KServe   → Install cert-manager, Istio, and KServe controller
#   Step 3: Llama    → Deploy the Llama 3.2 3B model via KServe InferenceService
#   Step 4: OpenClaw → Install OpenClaw pointing at the KServe model endpoint
#
# The script is designed to be run once for initial setup. It's also safe to
# re-run: Terraform is idempotent, Helm uses upgrade --install, and kubectl
# apply is idempotent.
#
# Total deployment time: ~15-25 minutes
#   - Terraform (GKE cluster creation): ~8-12 minutes
#   - KServe stack installation: ~3-5 minutes
#   - Model deployment + GPU scale-up: ~3-8 minutes (depends on spot availability)
#   - OpenClaw installation: ~1-2 minutes
#
# Prerequisites:
#   - gcloud authenticated (`gcloud auth login`)
#   - terraform/terraform.tfvars exists with your project_id
#   - HF_TOKEN env var set, OR kserve/hf-secret.yaml edited with your token
#
# Shell options:
#   set -e: Exit immediately if any command fails (non-zero exit code)
#   set -u: Treat unset variables as errors (catches typos)
#   set -o pipefail: A pipeline fails if ANY command in it fails (not just last)
# =============================================================================
set -euo pipefail

# Resolve the absolute path of this script's directory, regardless of where
# it's invoked from. All file references use $ROOT_DIR for portability.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# =============================================================================
# Model selection
# =============================================================================
# Supports three modes:
#   llama (default) — meta-llama/Llama-3.2-3B-Instruct (gated, needs license)
#   qwen           — Qwen/Qwen3.5-2B (open, no license needed)
#   openai         — OpenAI API (no GPU needed, requires OPENAI_API_KEY)
#
# Usage:
#   ./deploy.sh                 # Interactive prompt to choose model
#   ./deploy.sh --model llama   # Deploy with Llama 3.2 3B
#   ./deploy.sh --model qwen    # Deploy with Qwen 3.5 2B
#   ./deploy.sh --model openai  # Deploy with OpenAI API (no GPU)
# =============================================================================
MODEL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)
      MODEL="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: ./deploy.sh [--model llama|qwen|openai]"
      exit 1
      ;;
  esac
done

# If no --model flag was provided, prompt the user to choose interactively.
if [ -z "$MODEL" ]; then
  echo "Select a model backend:"
  echo "  1) llama  — Llama 3.2 3B Instruct (requires HF token + GPU)"
  echo "  2) qwen   — Qwen 3.5 2B (requires HF token + GPU)"
  echo "  3) openai — OpenAI API (no GPU needed, requires OPENAI_API_KEY)"
  echo ""
  read -rp "Enter choice [1/2/3] (default: 1): " choice
  case "${choice:-1}" in
    1) MODEL="llama" ;;
    2) MODEL="qwen" ;;
    3) MODEL="openai" ;;
    *)
      echo "ERROR: Invalid choice '$choice'."
      exit 1
      ;;
  esac
fi

case "$MODEL" in
  llama)
    ISVC_FILE="$ROOT_DIR/kserve/llama-inferenceservice.yaml"
    ISVC_NAME="llama-3-2b"
    OPENCLAW_VALUES="$ROOT_DIR/openclaw/values.yaml"
    MODEL_DISPLAY="Llama 3.2 3B Instruct"
    ;;
  qwen)
    ISVC_FILE="$ROOT_DIR/kserve/qwen-inferenceservice.yaml"
    ISVC_NAME="qwen-3-5-2b"
    OPENCLAW_VALUES="$ROOT_DIR/openclaw/values-qwen.yaml"
    MODEL_DISPLAY="Qwen 3.5 2B"
    ;;
  openai)
    ISVC_FILE=""
    ISVC_NAME=""
    OPENCLAW_VALUES="$ROOT_DIR/openclaw/values-openai.yaml"
    MODEL_DISPLAY="OpenAI API (gpt-4o-mini)"
    ;;
  *)
    echo "ERROR: Unknown model '$MODEL'. Use 'llama', 'qwen', or 'openai'."
    exit 1
    ;;
esac

echo "============================================"
echo "  OpenClaw + KServe Deployment"
echo "  Model: $MODEL_DISPLAY"
echo "============================================"
echo ""

# =============================================================================
# Pre-flight checks
# =============================================================================
# Verify all required CLI tools are installed before starting. This prevents
# confusing failures 10 minutes into the deployment because kubectl isn't
# installed.
# =============================================================================
for cmd in gcloud terraform kubectl helm; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: $cmd is not installed. Please install it first."
    exit 1
  fi
done

# Check that terraform.tfvars exists with the user's GCP project ID.
# Without this, Terraform would prompt interactively for the project_id
# variable, which doesn't work well in a scripted deployment.
if [ ! -f "$ROOT_DIR/terraform/terraform.tfvars" ]; then
  echo "ERROR: terraform/terraform.tfvars not found."
  echo "Copy terraform/terraform.tfvars.example and fill in your project ID."
  exit 1
fi

# =============================================================================
# Token handling
# =============================================================================
# For local models (llama/qwen): HF token is required for model downloads.
# For OpenAI mode: OPENAI_API_KEY is required instead.
# =============================================================================
if [ "$MODEL" = "openai" ]; then
  if [ -z "${OPENAI_API_KEY:-}" ]; then
    echo "ERROR: Set your OpenAI API key."
    echo "  export OPENAI_API_KEY=sk-..."
    exit 1
  fi
  echo "Using OpenAI API key from environment"
else
  # HF token can be provided two ways:
  #   1. Edit kserve/hf-secret.yaml directly (replace YOUR_HF_TOKEN)
  #   2. Set the HF_TOKEN environment variable (script patches the file)
  if ! grep -q 'YOUR_HF_TOKEN' "$ROOT_DIR/kserve/hf-secret.yaml" 2>/dev/null; then
    echo "Using configured HF token from hf-secret.yaml"
  else
    if [ -z "${HF_TOKEN:-}" ]; then
      echo "ERROR: Set your HuggingFace token."
      echo "Either edit kserve/hf-secret.yaml or export HF_TOKEN=hf_xxx"
      exit 1
    fi
    # Replace the placeholder in hf-secret.yaml with the actual token.
    # -i.bak creates a backup file (required by macOS sed), then we remove it.
    sed -i.bak "s/YOUR_HF_TOKEN/$HF_TOKEN/" "$ROOT_DIR/kserve/hf-secret.yaml"
    rm -f "$ROOT_DIR/kserve/hf-secret.yaml.bak"
  fi
fi

# =============================================================================
# Step 1: Provision GKE cluster via Terraform
# =============================================================================
# terraform init: Downloads the Google provider plugin (~200MB first time).
# terraform apply -auto-approve: Creates all resources without interactive
#   confirmation. This is safe here because the script is intentional.
#
# This step takes ~8-12 minutes (GKE cluster creation is slow).
# It creates:
#   - The GKE cluster control plane
#   - System node pool (1x e2-standard-2 spot — starts immediately)
#   - GPU node pool definition (0 nodes initially — scales up on demand)
# =============================================================================
echo ""
echo "=== Step 1: Provisioning GKE cluster ==="
cd "$ROOT_DIR/terraform"
terraform init
terraform apply -auto-approve
cd "$ROOT_DIR"

# =============================================================================
# Configure kubectl
# =============================================================================
# After Terraform creates the cluster, we need to configure kubectl to talk
# to it. The get_credentials_command output from Terraform contains the exact
# gcloud command needed. Example:
#   gcloud container clusters get-credentials openclaw-kserve \
#     --zone us-central1-a --project my-project
#
# This updates ~/.kube/config with the cluster's endpoint and auth info.
# =============================================================================
echo ""
echo "=== Configuring kubectl ==="
KUBECONFIG_CMD=$(cd "$ROOT_DIR/terraform" && terraform output -raw get_credentials_command)
eval "$KUBECONFIG_CMD"

# =============================================================================
# Step 2: Install KServe (cert-manager + Istio + KServe controller)
# =============================================================================
# Delegates to kserve/install-kserve.sh which handles the three-component
# installation. See that script for detailed comments on each component.
# =============================================================================
echo ""
echo "=== Step 2: Installing KServe ==="
bash "$ROOT_DIR/kserve/install-kserve.sh"

# =============================================================================
# Step 3: Deploy the model (skipped for OpenAI mode)
# =============================================================================
# For local models (llama/qwen):
#   1. hf-secret.yaml: Creates the Secret with the HuggingFace token
#   2. InferenceService YAML: Creates the KServe InferenceService resource
#
#   When the InferenceService is created, this chain of events occurs:
#     a. KServe controller creates a Deployment requesting 1x nvidia.com/gpu
#     b. The pod is unschedulable (no GPU nodes exist yet, pool is at 0)
#     c. GKE cluster autoscaler detects the unschedulable pod
#     d. Autoscaler provisions a g2-standard-4 + L4 spot VM (~2-5 min)
#     e. GKE installs NVIDIA drivers on the new node (~1 min)
#     f. Pod is scheduled, vLLM starts downloading the model from HF (~1-2 min)
#     g. vLLM loads the model into GPU VRAM and starts serving
#     h. KServe marks the InferenceService as Ready
#
# For OpenAI mode: No model to deploy — OpenClaw calls OpenAI's API directly.
# =============================================================================
if [ "$MODEL" = "openai" ]; then
  echo ""
  echo "=== Step 3: Skipped (using OpenAI API) ==="
else
  echo ""
  echo "=== Step 3: Deploying $MODEL_DISPLAY ==="
  kubectl apply -f "$ROOT_DIR/kserve/hf-secret.yaml"
  kubectl apply -f "$ISVC_FILE"

  echo "Waiting for InferenceService to become ready (this may take several minutes as GPU node scales up)..."
  kubectl wait --for=condition=Ready "inferenceservice/$ISVC_NAME" -n kserve --timeout=600s || {
    echo "WARNING: InferenceService not ready within 10 minutes."
    echo "Check status: kubectl get inferenceservice -n kserve"
    echo "Check pods: kubectl get pods -n kserve"
    echo "Continuing with OpenClaw install anyway..."
  }
fi

# =============================================================================
# Step 4: Install OpenClaw
# =============================================================================
# Delegates to openclaw/install-openclaw.sh which handles namespace creation,
# secret creation, and Helm installation. See that script for details.
#
# OpenClaw will start making requests to the KServe endpoint immediately.
# If the model isn't ready yet (still in Step 3), OpenClaw will get connection
# errors until the model pod becomes Ready. This is fine — OpenClaw retries
# on its own.
# =============================================================================
echo ""
echo "=== Step 4: Installing OpenClaw ==="
bash "$ROOT_DIR/openclaw/install-openclaw.sh" --values "$OPENCLAW_VALUES"

GATEWAY_TOKEN=$(kubectl get secret openclaw-env-secret -n openclaw -o jsonpath='{.data.OPENCLAW_GATEWAY_TOKEN}' | base64 -d 2>/dev/null || echo "UNKNOWN")

echo ""
echo "============================================"
echo "  Deployment Complete!"
echo "  Model: $MODEL_DISPLAY"
echo "============================================"
echo ""
echo "Verify:"
if [ "$MODEL" != "openai" ]; then
  echo "  kubectl get pods -n kserve"
  echo "  kubectl get inferenceservice -n kserve"
fi
echo "  kubectl get pods -n openclaw"
echo ""
echo "Access OpenClaw:"
echo "  kubectl port-forward -n openclaw svc/openclaw 18789:18789"
echo "  Open http://localhost:18789/?token=$GATEWAY_TOKEN"
