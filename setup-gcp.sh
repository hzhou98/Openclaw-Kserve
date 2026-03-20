#!/usr/bin/env bash
# =============================================================================
# setup-gcp.sh — Configure GCP project for OpenClaw + KServe deployment
# =============================================================================
#
# Run this BEFORE deploy.sh. It handles all the one-time GCP configuration
# that Terraform and GKE need:
#
#   1. Authenticate with Google Cloud
#   2. Create or select a GCP project
#   3. Link a billing account (required for any paid resources)
#   4. Enable required APIs (Compute, GKE, IAM)
#   5. Request GPU quota (T4 in us-central1)
#   6. Configure Terraform variables automatically
#   7. Install missing CLI tools (optional)
#
# This script is interactive — it will prompt you for choices along the way.
#
# Prerequisites:
#   - Google Cloud SDK (gcloud) installed
#     macOS:   brew install google-cloud-sdk
#     Linux:   curl https://sdk.cloud.google.com | bash
#     Windows: https://cloud.google.com/sdk/docs/install
#
# What you'll need:
#   - A Google account (personal Gmail or Google Workspace)
#   - A credit card for billing (free tier covers some costs)
#   - ~5 minutes for initial setup
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "============================================"
echo "  GCP Project Setup for OpenClaw + KServe"
echo "============================================"
echo ""

# =============================================================================
# Step 1: Check for gcloud CLI
# =============================================================================
# The Google Cloud SDK (gcloud) is the primary CLI tool for interacting with
# GCP. Everything in this script depends on it.
#
# gcloud is a suite of tools:
#   - gcloud: Manage GCP resources (projects, VMs, clusters, IAM)
#   - gsutil: Manage Cloud Storage buckets
#   - bq: Query BigQuery datasets
#
# We only need `gcloud` for this project.
# =============================================================================
if ! command -v gcloud &>/dev/null; then
  echo "ERROR: gcloud CLI is not installed."
  echo ""
  echo "Install it:"
  echo "  macOS:   brew install google-cloud-sdk"
  echo "  Linux:   curl https://sdk.cloud.google.com | bash"
  echo "  Windows: https://cloud.google.com/sdk/docs/install"
  echo ""
  echo "After installing, restart your terminal and run this script again."
  exit 1
fi

# =============================================================================
# Step 2: Authenticate with Google Cloud
# =============================================================================
# gcloud auth login opens a browser window where you sign in with your Google
# account. This creates OAuth credentials stored at:
#   ~/.config/gcloud/credentials.db
#
# These credentials are used by gcloud CLI commands. Terraform uses SEPARATE
# credentials — we set those up with `gcloud auth application-default login`
# which stores credentials that any Google SDK/library can use (including
# Terraform's google provider).
#
# The difference:
#   - `gcloud auth login`: Authenticates the gcloud CLI tool itself
#   - `gcloud auth application-default login`: Creates credentials for SDKs
#     and tools like Terraform, Python google-cloud libraries, etc.
#     Stored at: ~/.config/gcloud/application_default_credentials.json
#
# We need both because:
#   - gcloud commands in this script use `gcloud auth login` credentials
#   - Terraform uses Application Default Credentials (ADC)
# =============================================================================
echo "=== Step 1: Authentication ==="
echo ""

# Check if already authenticated
CURRENT_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null || true)
if [ -n "$CURRENT_ACCOUNT" ]; then
  echo "Currently authenticated as: $CURRENT_ACCOUNT"
  read -p "Use this account? (Y/n): " USE_CURRENT
  if [[ "$(echo "$USE_CURRENT" | tr '[:upper:]' '[:lower:]')" == "n" ]]; then
    echo "Opening browser for authentication..."
    gcloud auth login
  fi
else
  echo "Not authenticated. Opening browser for Google sign-in..."
  gcloud auth login
fi

# Set up Application Default Credentials for Terraform
echo ""
echo "Setting up Application Default Credentials (for Terraform)..."
if [ -f "$HOME/.config/gcloud/application_default_credentials.json" ]; then
  echo "ADC already configured."
else
  echo "This will open a browser window for a second authentication."
  echo "(Terraform needs its own credentials separate from gcloud CLI)"
  gcloud auth application-default login
fi

# =============================================================================
# Step 3: Create or select a GCP project
# =============================================================================
# Every GCP resource lives inside a "project". A project is the fundamental
# organizational unit that:
#   - Groups related resources together
#   - Has its own billing account
#   - Has its own IAM policies
#   - Has its own API enablement
#   - Has its own quotas
#
# Project IDs are globally unique across all of Google Cloud and cannot be
# changed after creation. Project names are just display labels.
#
# Best practice: Create a dedicated project for this deployment so you can
# easily see costs and tear everything down by deleting the project.
# =============================================================================
echo ""
echo "=== Step 2: Project Setup ==="
echo ""

# List existing projects
echo "Your existing GCP projects:"
gcloud projects list --format="table(projectId, name, projectNumber)" 2>/dev/null || echo "  (none found)"
echo ""

read -p "Create a new project? (Y/n): " CREATE_NEW
if [[ "$(echo "$CREATE_NEW" | tr '[:upper:]' '[:lower:]')" != "n" ]]; then
  # Generate a default project ID (must be globally unique, 6-30 chars,
  # lowercase letters, digits, hyphens)
  DEFAULT_PROJECT_ID="openclaw-kserve-$(date +%s | tail -c 7)"
  read -p "Project ID [$DEFAULT_PROJECT_ID]: " PROJECT_ID
  PROJECT_ID="${PROJECT_ID:-$DEFAULT_PROJECT_ID}"

  # ---------------------------------------------------------------------------
  # Check for GCP organizations
  # ---------------------------------------------------------------------------
  # If your Google account belongs to a company/institution (Google Workspace
  # or Cloud Identity), you'll have an organization. Projects created under
  # an org inherit IAM policies, billing constraints, and security controls.
  #
  # Hierarchy: Organization → Folders (optional) → Projects → Resources
  #
  # If no org exists (personal Gmail), the project is created standalone.
  # ---------------------------------------------------------------------------
  CREATE_FLAGS=("--name=OpenClaw-KServe" "--set-as-default")
  ORG_LIST=$(gcloud organizations list --format="value(ID,DISPLAY_NAME)" 2>/dev/null || true)

  if [ -n "$ORG_LIST" ]; then
    echo ""
    echo "Organizations found:"
    echo "$ORG_LIST" | while IFS=$'\t' read -r ORG_ID ORG_NAME; do
      echo "  $ORG_ID  ($ORG_NAME)"
    done
    echo ""

    ORG_COUNT=$(echo "$ORG_LIST" | wc -l | tr -d ' ')
    if [ "$ORG_COUNT" -eq 1 ]; then
      DEFAULT_ORG_ID=$(echo "$ORG_LIST" | head -1 | cut -f1)
    else
      DEFAULT_ORG_ID=""
    fi

    read -p "Create project under an organization? (Y/n): " USE_ORG
    if [[ "$(echo "$USE_ORG" | tr '[:upper:]' '[:lower:]')" != "n" ]]; then
      if [ -n "$DEFAULT_ORG_ID" ]; then
        read -p "Organization ID [$DEFAULT_ORG_ID]: " ORG_ID
        ORG_ID="${ORG_ID:-$DEFAULT_ORG_ID}"
      else
        read -p "Organization ID: " ORG_ID
      fi

      # Check for folders within the organization
      FOLDER_LIST=$(gcloud resource-manager folders list --organization="$ORG_ID" \
        --format="value(ID,DISPLAY_NAME)" 2>/dev/null || true)

      if [ -n "$FOLDER_LIST" ]; then
        echo ""
        echo "Folders in organization $ORG_ID:"
        echo "$FOLDER_LIST" | while IFS=$'\t' read -r FOLDER_ID FOLDER_NAME; do
          echo "  $FOLDER_ID  ($FOLDER_NAME)"
        done
        echo ""

        read -p "Create project under a folder? (y/N): " USE_FOLDER
        if [[ "$(echo "$USE_FOLDER" | tr '[:upper:]' '[:lower:]')" == "y" ]]; then
          read -p "Folder ID: " FOLDER_ID
          CREATE_FLAGS=("--name=OpenClaw-KServe" "--folder=$FOLDER_ID" "--set-as-default")
        else
          CREATE_FLAGS=("--name=OpenClaw-KServe" "--organization=$ORG_ID" "--set-as-default")
        fi
      else
        CREATE_FLAGS=("--name=OpenClaw-KServe" "--organization=$ORG_ID" "--set-as-default")
      fi
    fi
  fi

  echo "Creating project: $PROJECT_ID"
  gcloud projects create "$PROJECT_ID" "${CREATE_FLAGS[@]}"

  echo "Project created successfully."
else
  read -p "Enter existing project ID: " PROJECT_ID
  echo "Setting active project to: $PROJECT_ID"
  gcloud config set project "$PROJECT_ID"
fi

echo "Active project: $PROJECT_ID"

# =============================================================================
# Step 4: Link a billing account
# =============================================================================
# GCP requires a billing account linked to the project before you can create
# any paid resources (VMs, GPUs, disks, load balancers). Even with free tier,
# you need billing enabled.
#
# A billing account is where your credit card or payment method lives. One
# billing account can be linked to multiple projects. You can set budget
# alerts on billing accounts to avoid surprise charges.
#
# If you've never used GCP before, you likely have a $300 free trial credit
# that lasts 90 days. This is enough to run this project for 2-3 months.
#
# If no billing accounts exist, the script directs you to the Cloud Console
# to create one (requires a credit card).
# =============================================================================
echo ""
echo "=== Step 3: Billing ==="
echo ""

# Check if billing is already enabled
BILLING_ENABLED=$(gcloud billing projects describe "$PROJECT_ID" --format="value(billingEnabled)" 2>/dev/null || echo "false")
if [ "$BILLING_ENABLED" == "True" ]; then
  LINKED_ACCOUNT=$(gcloud billing projects describe "$PROJECT_ID" --format="value(billingAccountName)" 2>/dev/null)
  echo "Billing already enabled. Account: $LINKED_ACCOUNT"
else
  echo "Billing is NOT enabled for this project."
  echo ""

  # List available billing accounts
  echo "Available billing accounts:"
  BILLING_ACCOUNTS=$(gcloud billing accounts list --format="value(name,displayName)" 2>/dev/null || true)

  if [ -z "$BILLING_ACCOUNTS" ]; then
    echo "  No billing accounts found."
    echo ""
    echo "  You need to create a billing account first:"
    echo "  1. Go to: https://console.cloud.google.com/billing"
    echo "  2. Click 'Create Account'"
    echo "  3. Add a payment method"
    echo "  4. Run this script again"
    echo ""
    echo "  Note: New GCP accounts get \$300 free credit for 90 days."
    exit 1
  fi

  echo "$BILLING_ACCOUNTS" | while IFS=$'\t' read -r ACCOUNT_ID DISPLAY_NAME; do
    echo "  $ACCOUNT_ID  ($DISPLAY_NAME)"
  done
  echo ""

  # If there's only one billing account, use it automatically
  ACCOUNT_COUNT=$(echo "$BILLING_ACCOUNTS" | wc -l | tr -d ' ')
  if [ "$ACCOUNT_COUNT" -eq 1 ]; then
    BILLING_ACCOUNT_ID=$(echo "$BILLING_ACCOUNTS" | head -1 | cut -f1)
    echo "Using billing account: $BILLING_ACCOUNT_ID"
  else
    read -p "Enter billing account ID: " BILLING_ACCOUNT_ID
  fi

  echo "Linking billing account to project..."
  gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT_ID"
  echo "Billing enabled successfully."
fi

# =============================================================================
# Step 5: Enable required GCP APIs
# =============================================================================
# GCP APIs are disabled by default on new projects. Each API must be
# explicitly enabled before you can use it. This is a security measure
# that prevents accidental resource creation.
#
# APIs we need:
#
#   compute.googleapis.com
#     The Compute Engine API. Manages VMs, disks, networking, firewalls,
#     load balancers, and IP addresses. GKE nodes are Compute Engine VMs,
#     so this is required.
#
#   container.googleapis.com
#     The Google Kubernetes Engine API. Creates and manages GKE clusters,
#     node pools, and cluster operations. This is the main API Terraform
#     uses.
#
#   iam.googleapis.com
#     The Identity and Access Management API. Manages service accounts,
#     roles, and permissions. Needed for Workload Identity (allows pods
#     to authenticate to GCP services without key files).
#
#   iamcredentials.googleapis.com
#     The IAM Service Account Credentials API. Generates short-lived
#     credentials for service accounts. Required by Workload Identity.
#
#   cloudresourcemanager.googleapis.com
#     The Cloud Resource Manager API. Manages projects and organizations.
#     Terraform needs this to verify the project exists and read its
#     configuration.
#
# API enablement takes 30-60 seconds per API and is a one-time operation.
# Terraform also enables compute and container APIs, but doing it here
# ensures they're ready before Terraform runs (avoids race conditions).
# =============================================================================
echo ""
echo "=== Step 4: Enabling APIs ==="
echo ""
echo "Enabling required GCP APIs (this takes ~1-2 minutes)..."

APIS=(
  "compute.googleapis.com"
  "container.googleapis.com"
  "iam.googleapis.com"
  "iamcredentials.googleapis.com"
  "cloudresourcemanager.googleapis.com"
)

for api in "${APIS[@]}"; do
  echo "  Enabling $api..."
  gcloud services enable "$api" --project="$PROJECT_ID" --quiet
done

echo "All APIs enabled."

# =============================================================================
# Step 6: Check and request GPU quota
# =============================================================================
# GCP enforces quotas (limits) on every resource type to prevent abuse and
# ensure fair usage. New projects often have a GPU quota of ZERO, meaning
# you cannot create any GPU VMs until you request an increase.
#
# The quota we need:
#   - Resource: NVIDIA_T4_GPUS
#   - Region: us-central1
#   - Required: at least 1 (we use 1 GPU per node, up to 2 nodes)
#   - Recommended: 2 (allows the max_node_count=2 in our GPU pool)
#
# If the quota is 0, you must request an increase through the GCP Console.
# Quota increases are reviewed by Google and typically approved within:
#   - Minutes to hours for paid accounts with history
#   - 24-48 hours for new accounts
#   - Some new accounts may need to wait until free trial is over
#
# Alternative: If quota takes too long, you can:
#   1. Try a different zone (us-central1-b, us-east1-b, etc.)
#   2. Try a different GPU type (T4 usually has best availability)
#   3. Use a CPU-only setup temporarily (slower inference but works)
# =============================================================================
echo ""
echo "=== Step 5: GPU Quota Check ==="
echo ""

# Check T4 GPU quota in the target region.
# We output JSON and extract the NVIDIA_T4_GPUS quota using grep + awk.
# This avoids a Python dependency.
T4_QUOTA=$(gcloud compute regions describe us-central1 \
  --project="$PROJECT_ID" \
  --format=json 2>/dev/null | \
  awk '
    /"metric": "NVIDIA_T4_GPUS"/ { found=1 }
    found && /"limit"/ { gsub(/[^0-9.]/, "", $2); limit=$2 }
    found && /"usage"/ { gsub(/[^0-9.]/, "", $2); usage=$2; printf "%d|%d\n", limit, usage; exit }
    END { if (!found) print "0|0" }
  ' 2>/dev/null || echo "0|0")

T4_LIMIT=$(echo "$T4_QUOTA" | cut -d'|' -f1)
T4_USAGE=$(echo "$T4_QUOTA" | cut -d'|' -f2)

echo "T4 GPU quota in us-central1:"
echo "  Limit: $T4_LIMIT"
echo "  In use: $T4_USAGE"
echo "  Available: $((T4_LIMIT - T4_USAGE))"

if [ "$T4_LIMIT" -lt 1 ]; then
  echo ""
  echo "WARNING: Your T4 GPU quota is 0. You need at least 1."
  echo ""
  echo "Request a quota increase:"
  echo "  1. Go to: https://console.cloud.google.com/iam-admin/quotas?project=$PROJECT_ID"
  echo "  2. Filter by: 'NVIDIA T4' or search 'GPU'"
  echo "  3. Select 'NVIDIA T4 GPUs' for region 'us-central1'"
  echo "  4. Click 'Edit Quotas'"
  echo "  5. Request a new limit of 2"
  echo "  6. Add justification: 'ML model serving for development'"
  echo "  7. Submit and wait for approval"
  echo ""
  echo "Typical approval time: minutes to 48 hours for new accounts."
  echo ""
  echo "You can continue with the setup — Terraform will create the cluster"
  echo "and system pool. The GPU pool will remain at 0 nodes until quota is"
  echo "approved and you deploy the InferenceService."
  echo ""
  read -p "Continue anyway? (Y/n): " CONTINUE
  if [[ "$(echo "$CONTINUE" | tr '[:upper:]' '[:lower:]')" == "n" ]]; then
    echo "Setup paused. Run this script again after quota is approved."
    exit 0
  fi
else
  echo "GPU quota is sufficient."
fi

# =============================================================================
# Step 7: Set default compute region and zone
# =============================================================================
# gcloud stores default values in a local configuration profile. Setting
# defaults here means you don't need to pass --region and --zone to every
# gcloud command.
#
# us-central1-a is chosen because:
#   - T4 GPUs have good availability
#   - Spot prices are competitive
#   - Zonal cluster control plane is free
#   - Central US has decent latency for most US-based users
# =============================================================================
echo ""
echo "=== Step 6: Setting Defaults ==="
echo ""

gcloud config set compute/region us-central1 --quiet
gcloud config set compute/zone us-central1-a --quiet
echo "Default region: us-central1"
echo "Default zone: us-central1-a"

# =============================================================================
# Step 8: Write Terraform variables
# =============================================================================
# Automatically create terraform.tfvars with the project ID from this setup.
# This saves you from manually editing the file.
# =============================================================================
echo ""
echo "=== Step 7: Configuring Terraform ==="
echo ""

TFVARS_FILE="$ROOT_DIR/terraform/terraform.tfvars"
cat > "$TFVARS_FILE" <<EOF
project_id = "$PROJECT_ID"
region     = "us-central1"
zone       = "us-central1-a"
EOF

echo "Written to: terraform/terraform.tfvars"
echo "  project_id = \"$PROJECT_ID\""
echo "  region     = \"us-central1\""
echo "  zone       = \"us-central1-a\""

# =============================================================================
# Step 9: Check for other required CLI tools
# =============================================================================
# The deployment needs these tools beyond gcloud:
#
#   terraform: Infrastructure-as-code for creating the GKE cluster
#     Terraform reads .tf files and calls GCP APIs to create resources.
#     State is stored locally in terraform.tfstate (or remotely in a bucket).
#
#   kubectl: Kubernetes CLI for managing workloads in the cluster
#     Talks to the Kubernetes API server. Configured via ~/.kube/config.
#     gcloud container clusters get-credentials sets this up automatically.
#
#   helm: Kubernetes package manager for installing complex applications
#     Helm "charts" are parameterized bundles of Kubernetes manifests.
#     KServe, Istio, cert-manager, and OpenClaw are all installed via Helm.
# =============================================================================
echo ""
echo "=== Step 8: Checking CLI Tools ==="
echo ""

MISSING_TOOLS=()

if command -v terraform &>/dev/null; then
  echo "  terraform: $(terraform version -json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["terraform_version"])' 2>/dev/null || terraform version | head -1)"
else
  MISSING_TOOLS+=("terraform")
  echo "  terraform: NOT INSTALLED"
  echo "    Install: https://developer.hashicorp.com/terraform/install"
  echo "    macOS:   brew install terraform"
  echo "    Linux:   sudo apt install terraform  (or download from hashicorp.com)"
fi

if command -v kubectl &>/dev/null; then
  echo "  kubectl: $(kubectl version --client -o json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["clientVersion"]["gitVersion"])' 2>/dev/null || echo 'installed')"
else
  MISSING_TOOLS+=("kubectl")
  echo "  kubectl: NOT INSTALLED"
  echo "    Install: gcloud components install kubectl"
  echo "    Or:      brew install kubectl"
fi

if command -v helm &>/dev/null; then
  echo "  helm: $(helm version --short 2>/dev/null)"
else
  MISSING_TOOLS+=("helm")
  echo "  helm: NOT INSTALLED"
  echo "    Install: https://helm.sh/docs/intro/install/"
  echo "    macOS:   brew install helm"
  echo "    Linux:   curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
fi

if [ ${#MISSING_TOOLS[@]} -gt 0 ]; then
  echo ""
  echo "WARNING: Missing tools: ${MISSING_TOOLS[*]}"
  echo "Install them before running deploy.sh"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "============================================"
echo "  GCP Setup Complete!"
echo "============================================"
echo ""
echo "Project ID:     $PROJECT_ID"
echo "Region:         us-central1"
echo "Zone:           us-central1-a"
echo "Billing:        enabled"
echo "APIs:           enabled"
echo "GPU Quota (T4): ${T4_LIMIT} (need >=1)"
echo "Terraform:      terraform/terraform.tfvars configured"
echo ""
if [ "$T4_LIMIT" -lt 1 ]; then
  echo "NEXT STEPS:"
  echo "  1. Request GPU quota increase (see instructions above)"
  echo "  2. Accept HuggingFace Llama license: https://huggingface.co/meta-llama/Llama-3.2-3B-Instruct"
  echo "  3. Get HF token: https://huggingface.co/settings/tokens"
  echo "  4. export HF_TOKEN=hf_your_token"
  echo "  5. ./deploy.sh"
else
  echo "NEXT STEPS:"
  echo "  1. Accept HuggingFace Llama license: https://huggingface.co/meta-llama/Llama-3.2-3B-Instruct"
  echo "  2. Get HF token: https://huggingface.co/settings/tokens"
  echo "  3. export HF_TOKEN=hf_your_token"
  echo "  4. ./deploy.sh"
fi
