#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Master deployment script for OpenClaw + KServe on GKE
# =============================================================================
#
# This script orchestrates the complete deployment in four sequential steps:
#
#   Step 1: Terraform → Provision GKE cluster with system + GPU node pools
#   Step 2: KServe   → Install cert-manager, Istio, and KServe controller
#                       (skipped for OpenAI mode — not needed)
#   Step 3: Model    → Deploy the model via KServe InferenceService
#                       (skipped for OpenAI mode — calls OpenAI API directly)
#   Step 4: OpenClaw → Install OpenClaw pointing at the model endpoint
#
# The script is designed to be run once for initial setup. It's also safe to
# re-run: Terraform is idempotent, Helm uses upgrade --install, and kubectl
# apply is idempotent.
#
# Total deployment time:
#   Local models (llama/qwen): ~15-25 minutes
#     - Terraform (GKE cluster creation): ~8-12 minutes
#     - KServe stack installation: ~3-5 minutes
#     - Model deployment + GPU scale-up: ~3-8 minutes
#     - OpenClaw installation: ~1-2 minutes
#   OpenAI mode: ~10-15 minutes
#     - Terraform: ~8-12 minutes
#     - OpenClaw installation: ~1-2 minutes
#
# Prerequisites:
#   - gcloud authenticated (`gcloud auth login`)
#   - terraform/terraform.tfvars exists with your project_id
#   - Local models: HF_TOKEN env var set, OR kserve/hf-secret.yaml edited
#   - OpenAI mode: OPENAI_API_KEY env var set
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
# Model selection & skills
# =============================================================================
# Supports four model modes:
#   llama (default) — meta-llama/Llama-3.2-3B-Instruct (gated, needs license)
#   qwen           — Qwen/Qwen3.5-2B (open, no license needed)
#   openai         — OpenAI API (no GPU needed, requires OPENAI_API_KEY)
#   anthropic      — Anthropic API (no GPU needed, requires ANTHROPIC_API_KEY)
#
# The --api-model flag selects a specific model within a cloud API provider.
# If omitted, an interactive prompt is shown (or defaults are used).
# The --skills flag enables ClawHub skill installation (values-skills.yaml).
#
# Usage:
#   ./deploy.sh                                      # Interactive prompt
#   ./deploy.sh --model llama                        # Llama 3.2 3B
#   ./deploy.sh --model openai                       # OpenAI (interactive model choice)
#   ./deploy.sh --model openai --api-model gpt-4.1   # OpenAI with GPT-4.1
#   ./deploy.sh --model anthropic --api-model claude-opus-4-20250514
#   ./deploy.sh --model openai --skills              # OpenAI + skills
# =============================================================================
MODEL=""
API_MODEL=""
ENABLE_SKILLS=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)
      MODEL="$2"
      shift 2
      ;;
    --api-model)
      API_MODEL="$2"
      shift 2
      ;;
    --skills)
      ENABLE_SKILLS=true
      shift
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: ./deploy.sh [--model llama|qwen|openai|anthropic] [--api-model <model-id>] [--skills]"
      exit 1
      ;;
  esac
done

# =============================================================================
# Supported cloud API models (validated list)
# =============================================================================
# These lists define which model IDs are accepted by --api-model.
# Update these when new models are released.
# =============================================================================
OPENAI_MODELS=(
  "gpt-4o"
  "gpt-4o-mini"
  "gpt-4.1"
  "gpt-4.1-mini"
  "gpt-4.1-nano"
  "o3"
  "o3-mini"
  "o4-mini"
)

ANTHROPIC_MODELS=(
  "claude-opus-4-6"
  "claude-sonnet-4-6"
  "claude-haiku-4-5-20251001"
)

# Validate --api-model against supported list, with live API fallback
validate_api_model() {
  local provider="$1"
  local model="$2"
  local valid_models=()

  case "$provider" in
    openai)    valid_models=("${OPENAI_MODELS[@]}") ;;
    anthropic) valid_models=("${ANTHROPIC_MODELS[@]}") ;;
    *)
      echo "ERROR: --api-model is only supported with --model openai or --model anthropic."
      exit 1
      ;;
  esac

  # Check hardcoded list first (fast, works offline)
  for m in "${valid_models[@]}"; do
    if [ "$m" = "$model" ]; then
      return 0
    fi
  done

  # Not in hardcoded list — try validating against the live API
  echo "Model '$model' not in known list, checking $provider API..."

  if [ "$provider" = "openai" ]; then
    if [ -z "${OPENAI_API_KEY:-}" ]; then
      echo "ERROR: Cannot validate model — OPENAI_API_KEY not set."
      echo ""
      echo "Known OpenAI models:"
      for m in "${valid_models[@]}"; do echo "  - $m"; done
      exit 1
    fi
    # Query the OpenAI /v1/models endpoint and check if the model exists
    local api_response
    api_response=$(curl -s -w "\n%{http_code}" \
      "https://api.openai.com/v1/models/$model" \
      -H "Authorization: Bearer $OPENAI_API_KEY" 2>/dev/null)
    local http_code
    http_code=$(echo "$api_response" | tail -1)
    if [ "$http_code" = "200" ]; then
      echo "Model '$model' verified via OpenAI API"
      return 0
    fi
  elif [ "$provider" = "anthropic" ]; then
    if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
      echo "ERROR: Cannot validate model — ANTHROPIC_API_KEY not set."
      echo ""
      echo "Known Anthropic models:"
      for m in "${valid_models[@]}"; do echo "  - $m"; done
      exit 1
    fi
    # Query the Anthropic /v1/models endpoint and check if the model exists
    local api_response
    api_response=$(curl -s -w "\n%{http_code}" \
      "https://api.anthropic.com/v1/models/$model" \
      -H "anthropic-version: 2023-06-01" \
      -H "X-Api-Key: $ANTHROPIC_API_KEY" 2>/dev/null)
    local http_code
    http_code=$(echo "$api_response" | tail -1)
    if [ "$http_code" = "200" ]; then
      echo "Model '$model' verified via Anthropic API"
      return 0
    fi
  fi

  echo "ERROR: Model '$model' not found for $provider."
  echo ""
  echo "Known $provider models:"
  for m in "${valid_models[@]}"; do
    echo "  - $m"
  done
  echo ""
  echo "If this is a new model, check that your API key has access to it."
  exit 1
}

# If no --model flag was provided, prompt the user to choose interactively.
if [ -z "$MODEL" ]; then
  echo "Select a model backend:"
  echo "  1) llama     — Llama 3.2 3B Instruct (requires HF token + GPU)"
  echo "  2) qwen      — Qwen 3.5 2B (requires HF token + GPU)"
  echo "  3) openai    — OpenAI API (no GPU needed, requires OPENAI_API_KEY)"
  echo "  4) anthropic — Anthropic API (no GPU needed, requires ANTHROPIC_API_KEY)"
  echo ""
  read -rp "Enter choice [1/2/3/4] (default: 1): " choice
  case "${choice:-1}" in
    1) MODEL="llama" ;;
    2) MODEL="qwen" ;;
    3) MODEL="openai" ;;
    4) MODEL="anthropic" ;;
    *)
      echo "ERROR: Invalid choice '$choice'."
      exit 1
      ;;
  esac
fi

# If using a cloud API and no --api-model was given, use defaults.
# OpenAI: gpt-4o-mini (cheapest), Anthropic: claude-haiku-4-5-20251001 (cheapest)
if [ "$MODEL" = "openai" ] && [ -z "$API_MODEL" ]; then
  API_MODEL="gpt-4o-mini"
elif [ "$MODEL" = "anthropic" ] && [ -z "$API_MODEL" ]; then
  API_MODEL="claude-haiku-4-5-20251001"
fi

# Validate --api-model if provided via flag
if [ -n "$API_MODEL" ]; then
  validate_api_model "$MODEL" "$API_MODEL"
fi

case "$MODEL" in
  llama)
    ISVC_FILE="$ROOT_DIR/kserve/llama-inferenceservice.yaml"
    ISVC_NAME="llama-3-2b"
    OPENCLAW_VALUES=("$ROOT_DIR/openclaw/values.yaml")
    MODEL_DISPLAY="Llama 3.2 3B Instruct"
    ;;
  qwen)
    ISVC_FILE="$ROOT_DIR/kserve/qwen-inferenceservice.yaml"
    ISVC_NAME="qwen-3-5-2b"
    OPENCLAW_VALUES=("$ROOT_DIR/openclaw/values-qwen.yaml")
    MODEL_DISPLAY="Qwen 3.5 2B"
    ;;
  openai)
    ISVC_FILE=""
    ISVC_NAME=""
    API_MODEL="${API_MODEL:-gpt-4o-mini}"
    OPENCLAW_VALUES=("$ROOT_DIR/openclaw/values-openai.yaml")
    MODEL_DISPLAY="OpenAI API ($API_MODEL)"
    ;;
  anthropic)
    ISVC_FILE=""
    ISVC_NAME=""
    API_MODEL="${API_MODEL:-claude-haiku-4-5-20251001}"
    OPENCLAW_VALUES=("$ROOT_DIR/openclaw/values-anthropic.yaml")
    MODEL_DISPLAY="Anthropic API ($API_MODEL)"
    ;;
  *)
    echo "ERROR: Unknown model '$MODEL'. Use 'llama', 'qwen', 'openai', or 'anthropic'."
    exit 1
    ;;
esac

# Append skills overlay if --skills was specified
if [ "$ENABLE_SKILLS" = true ]; then
  OPENCLAW_VALUES+=("$ROOT_DIR/openclaw/values-skills.yaml")
fi

echo "============================================"
echo "  OpenClaw + KServe Deployment"
echo "  Model: $MODEL_DISPLAY"
if [ "$ENABLE_SKILLS" = true ]; then
echo "  Skills: enabled"
fi
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
# For cloud APIs: OPENAI_API_KEY or ANTHROPIC_API_KEY is required instead.
# =============================================================================
if [ "$MODEL" = "openai" ]; then
  if [ -z "${OPENAI_API_KEY:-}" ]; then
    echo "ERROR: Set your OpenAI API key."
    echo "  export OPENAI_API_KEY=sk-..."
    exit 1
  fi
  echo "Using OpenAI API key from environment"
elif [ "$MODEL" = "anthropic" ]; then
  if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    echo "ERROR: Set your Anthropic API key."
    echo "  export ANTHROPIC_API_KEY=sk-ant-..."
    exit 1
  fi
  echo "Using Anthropic API key from environment"
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
# Step 2: Install KServe (skipped for OpenAI mode)
# =============================================================================
# For local models (llama/qwen):
#   Delegates to kserve/install-kserve.sh which installs cert-manager, Istio,
#   and the KServe controller. See that script for detailed comments.
#
# For cloud API modes (openai/anthropic):
#   KServe is not needed — OpenClaw calls the API directly over the
#   internet. Skipping also avoids installing cert-manager and Istio, which
#   saves ~500MB RAM on the system pool and ~3-5 min of deploy time.
# =============================================================================
if [ "$MODEL" = "openai" ] || [ "$MODEL" = "anthropic" ]; then
  echo ""
  echo "=== Step 2: Skipped (KServe not needed for cloud API) ==="
else
  echo ""
  echo "=== Step 2: Installing KServe ==="
  bash "$ROOT_DIR/kserve/install-kserve.sh"
fi

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
# For cloud API modes: No model to deploy — OpenClaw calls the API directly.
# =============================================================================
if [ "$MODEL" = "openai" ] || [ "$MODEL" = "anthropic" ]; then
  echo ""
  echo "=== Step 3: Skipped (using cloud API) ==="
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

# If a non-default API model was selected, patch the values file to set it as
# the default. We create a temporary copy and substitute the "primary" model.
if [ -n "$API_MODEL" ]; then
  VALUES_SRC="${OPENCLAW_VALUES[0]}"
  TEMP_VALUES=$(mktemp /tmp/openclaw-values-XXXXXX.yaml)
  trap 'rm -f "$TEMP_VALUES"' EXIT

  if [ "$MODEL" = "openai" ]; then
    # Replace the default primary model (openai/gpt-4o-mini → openai/$API_MODEL)
    sed "s|\"primary\": \"openai/[^\"]*\"|\"primary\": \"openai/$API_MODEL\"|" \
      "$VALUES_SRC" > "$TEMP_VALUES"
  elif [ "$MODEL" = "anthropic" ]; then
    # Replace the default primary model (anthropic/claude-... → anthropic/$API_MODEL)
    sed "s|\"primary\": \"anthropic/[^\"]*\"|\"primary\": \"anthropic/$API_MODEL\"|" \
      "$VALUES_SRC" > "$TEMP_VALUES"
  fi

  OPENCLAW_VALUES[0]="$TEMP_VALUES"
  echo "Using API model: $API_MODEL"
fi

OPENCLAW_INSTALL_ARGS=()
for vf in "${OPENCLAW_VALUES[@]}"; do
  OPENCLAW_INSTALL_ARGS+=(--values "$vf")
done
bash "$ROOT_DIR/openclaw/install-openclaw.sh" "${OPENCLAW_INSTALL_ARGS[@]}"

GATEWAY_TOKEN=$(kubectl get secret openclaw-env-secret -n openclaw -o jsonpath='{.data.OPENCLAW_GATEWAY_TOKEN}' | base64 -d 2>/dev/null || echo "UNKNOWN")

echo ""
echo "============================================"
echo "  Deployment Complete!"
echo "  Model: $MODEL_DISPLAY"
echo "============================================"
echo ""
echo "Verify:"
if [ "$MODEL" != "openai" ] && [ "$MODEL" != "anthropic" ]; then
  echo "  kubectl get pods -n kserve"
  echo "  kubectl get inferenceservice -n kserve"
fi
echo "  kubectl get pods -n openclaw"
echo ""
echo "Access OpenClaw:"
echo "  kubectl port-forward -n openclaw svc/openclaw 18789:18789"
echo "  Open http://localhost:18789/?token=$GATEWAY_TOKEN"
