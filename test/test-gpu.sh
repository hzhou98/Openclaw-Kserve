#!/usr/bin/env bash
# =============================================================================
# test-gpu.sh — Test GPU availability in GCP
# =============================================================================
#
# Creates a minimal spot VM with a T4 or L4 GPU to verify availability.
# If no zone is provided, automatically scans all zones that support the
# GPU type until one succeeds.
#
# Usage:
#   ./test-gpu.sh                                # Auto-scan zones for T4
#   ./test-gpu.sh --gpu l4                       # Auto-scan zones for L4
#   ./test-gpu.sh --gpu t4 --zone us-west4-a     # Test specific zone
#   ./test-gpu.sh --gpu l4 --region us-central1  # Scan zones in region
#   ./test-gpu.sh --project my-project --gpu t4
#
# Modes:
#   --zone:   Test a single specific zone
#   --region: Scan only zones in this region (e.g., us-central1)
#   (neither): Scan ALL zones that support the GPU type
#
# What it does:
#   1. Queries GCP for zones that support the requested GPU type
#   2. Tries to create a spot VM in each zone until one succeeds
#   3. On success: prints the zone and VM details
#   4. On failure: reports which zones were tried and why they failed
#
# Common failure reasons:
#   - ZONE_RESOURCE_POOL_EXHAUSTED: No GPUs available in this zone right now
#   - QUOTA_EXCEEDED: Your project needs a GPU quota increase
#   - UNSUPPORTED_OPERATION: GPU type not available in this zone
#
# Cost: Spot T4 ~$0.11/hr, Spot L4 ~$0.17/hr. Clean up promptly!
# =============================================================================
set -euo pipefail

# Defaults
GPU_TYPE="t4"
ZONE=""
REGION=""
PROJECT=""
VM_NAME="gpu-test"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --gpu)      GPU_TYPE="$2"; shift 2 ;;
    --zone)     ZONE="$2"; shift 2 ;;
    --region)   REGION="$2"; shift 2 ;;
    --project)  PROJECT="$2"; shift 2 ;;
    --name)     VM_NAME="$2"; shift 2 ;;
    --help|-h)
      head -30 "$0" | tail -25
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: ./test-gpu.sh [--gpu t4|l4] [--zone ZONE] [--region REGION] [--project PROJECT]"
      exit 1
      ;;
  esac
done

# Resolve project from gcloud config if not provided
if [ -z "$PROJECT" ]; then
  PROJECT=$(gcloud config get-value project 2>/dev/null || true)
  if [ -z "$PROJECT" ]; then
    echo "ERROR: No project set. Use --project or run: gcloud config set project <PROJECT_ID>"
    exit 1
  fi
fi

# GPU type → machine type + accelerator mapping
case "$GPU_TYPE" in
  t4)
    MACHINE_TYPE="n1-standard-4"
    ACCELERATOR="type=nvidia-tesla-t4,count=1"
    ACCEL_FILTER="nvidia-tesla-t4"
    GPU_DISPLAY="NVIDIA T4 (16GB VRAM)"
    ;;
  l4)
    MACHINE_TYPE="g2-standard-4"
    ACCELERATOR=""
    ACCEL_FILTER="nvidia-l4"
    GPU_DISPLAY="NVIDIA L4 (24GB VRAM)"
    ;;
  *)
    echo "ERROR: Unknown GPU type '$GPU_TYPE'. Use 't4' or 'l4'."
    exit 1
    ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
# try_create_vm — Attempt to create a GPU VM in a given zone
# Returns 0 on success, 1 on failure
# ─────────────────────────────────────────────────────────────────────────────
try_create_vm() {
  local zone="$1"

  # Check if VM already exists in this zone
  if gcloud compute instances describe "$VM_NAME" --zone="$zone" --project="$PROJECT" &>/dev/null; then
    echo "  SKIP: VM '$VM_NAME' already exists in $zone"
    return 1
  fi

  CMD=(
    gcloud compute instances create "$VM_NAME"
    --project="$PROJECT"
    --zone="$zone"
    --machine-type="$MACHINE_TYPE"
    --provisioning-model=SPOT
    --instance-termination-action=STOP
    --boot-disk-size=20GB
    --boot-disk-type=pd-standard
    --image-family=cos-stable
    --image-project=cos-cloud
    --no-restart-on-failure
    --metadata=google-logging-enabled=false
  )

  if [ -n "$ACCELERATOR" ]; then
    CMD+=(--accelerator="$ACCELERATOR")
    CMD+=(--maintenance-policy=TERMINATE)
  fi

  if "${CMD[@]}" 2>/dev/null; then
    return 0
  else
    return 1
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# print_success — Show VM details after successful creation
# ─────────────────────────────────────────────────────────────────────────────
print_success() {
  local zone="$1"

  echo ""
  echo "============================================"
  echo "  SUCCESS: $GPU_TYPE GPU is available!"
  echo "  Zone:    $zone"
  echo "  Region:  ${zone%-*}"
  echo "  Project: $PROJECT"
  echo "============================================"
  echo ""

  echo "VM status:"
  gcloud compute instances describe "$VM_NAME" \
    --zone="$zone" --project="$PROJECT" \
    --format="table(name, status, machineType.basename(), scheduling.provisioningModel, zone.basename())"

  if [ -n "$ACCELERATOR" ]; then
    echo ""
    echo "GPU details:"
    gcloud compute instances describe "$VM_NAME" \
      --zone="$zone" --project="$PROJECT" \
      --format="yaml(guestAccelerators)"
  fi

  echo ""
  echo "IMPORTANT: Clean up to stop charges:"
  echo "  ./test-gpu-cleanup.sh --zone $zone --project $PROJECT --name $VM_NAME"
}

# ─────────────────────────────────────────────────────────────────────────────
# Mode 1: Specific zone provided — test just that zone
# ─────────────────────────────────────────────────────────────────────────────
if [ -n "$ZONE" ]; then
  echo "============================================"
  echo "  GPU Availability Test"
  echo "  GPU:     $GPU_DISPLAY"
  echo "  Zone:    $ZONE"
  echo "  Project: $PROJECT"
  echo "============================================"
  echo ""
  echo "Creating spot VM with $GPU_TYPE GPU in $ZONE..."

  if try_create_vm "$ZONE"; then
    print_success "$ZONE"
  else
    echo ""
    echo "============================================"
    echo "  FAILED: $GPU_TYPE GPU not available"
    echo "  Zone: $ZONE"
    echo "============================================"
    echo ""
    echo "Try without --zone to auto-scan all available zones:"
    echo "  ./test-gpu.sh --gpu $GPU_TYPE"
    exit 1
  fi
  exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# Mode 2: Auto-scan zones (optionally filtered by --region)
# ─────────────────────────────────────────────────────────────────────────────
echo "============================================"
echo "  GPU Availability Scan"
echo "  GPU:     $GPU_DISPLAY"
if [ -n "$REGION" ]; then
echo "  Region:  $REGION"
fi
echo "  Project: $PROJECT"
echo "============================================"
echo ""

# Query GCP for zones that support this GPU type
echo "Fetching zones with $GPU_TYPE support..."
FILTER="name=$ACCEL_FILTER"
if [ -n "$REGION" ]; then
  FILTER="name=$ACCEL_FILTER AND zone~$REGION"
fi

ZONES=$(gcloud compute accelerator-types list \
  --project="$PROJECT" \
  --filter="$FILTER" \
  --format="value(zone)" \
  --sort-by=zone 2>/dev/null | sort -u)

if [ -z "$ZONES" ]; then
  echo ""
  if [ -n "$REGION" ]; then
    echo "ERROR: No zones in region '$REGION' support $GPU_TYPE."
    echo ""
    echo "Try without --region to scan all regions:"
    echo "  ./test-gpu.sh --gpu $GPU_TYPE"
  else
    echo "ERROR: No zones found with $GPU_TYPE support in project $PROJECT."
    echo "You may need to enable the Compute Engine API or request GPU quota."
  fi
  exit 1
fi

ZONE_COUNT=$(echo "$ZONES" | wc -l | tr -d ' ')
echo "Found $ZONE_COUNT zone(s) with $GPU_TYPE support:"
echo "$ZONES" | while read -r z; do echo "  $z"; done
echo ""
echo "Testing zones one by one..."
echo ""

TRIED=()
FOUND_ZONE=""

for z in $ZONES; do
  echo "[$((${#TRIED[@]} + 1))/$ZONE_COUNT] Trying $z..."
  TRIED+=("$z")

  if try_create_vm "$z"; then
    FOUND_ZONE="$z"
    break
  else
    echo "  FAILED: $z — GPU not available (resource exhausted or quota)"
  fi
done

if [ -n "$FOUND_ZONE" ]; then
  print_success "$FOUND_ZONE"
  echo ""
  echo "To use this zone in your deployment, update terraform/terraform.tfvars:"
  echo "  zone = \"$FOUND_ZONE\""
  echo "  region = \"${FOUND_ZONE%-*}\""
else
  echo ""
  echo "============================================"
  echo "  FAILED: $GPU_TYPE not available in any zone"
  echo "============================================"
  echo ""
  echo "Tried ${#TRIED[@]} zone(s):"
  for z in "${TRIED[@]}"; do
    echo "  - $z"
  done
  echo ""
  echo "Possible fixes:"
  echo "  1. Request GPU quota: https://console.cloud.google.com/iam-admin/quotas"
  echo "     Search for 'NVIDIA' and request for your desired region"
  echo "  2. Try again later (spot GPUs fluctuate with demand)"
  echo "  3. Try the other GPU type: ./test-gpu.sh --gpu $([ "$GPU_TYPE" = "t4" ] && echo "l4" || echo "t4")"
  exit 1
fi
