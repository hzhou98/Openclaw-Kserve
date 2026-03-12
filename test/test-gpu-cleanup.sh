#!/usr/bin/env bash
# =============================================================================
# test-gpu-cleanup.sh — Delete the GPU test VM
# =============================================================================
#
# Deletes the VM created by test-gpu.sh to stop billing.
#
# Usage:
#   ./test-gpu-cleanup.sh                              # Delete default VM
#   ./test-gpu-cleanup.sh --zone us-central1-a         # Specify zone
#   ./test-gpu-cleanup.sh --name my-test --zone us-east4-c
#   ./test-gpu-cleanup.sh --all                        # Delete all gpu-test* VMs
#
# =============================================================================
set -euo pipefail

ZONE=""
PROJECT=""
VM_NAME="gpu-test"
DELETE_ALL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --zone)     ZONE="$2"; shift 2 ;;
    --project)  PROJECT="$2"; shift 2 ;;
    --name)     VM_NAME="$2"; shift 2 ;;
    --all)      DELETE_ALL=true; shift ;;
    --help|-h)
      head -14 "$0" | tail -10
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: ./test-gpu-cleanup.sh [--zone ZONE] [--project PROJECT] [--name NAME] [--all]"
      exit 1
      ;;
  esac
done

# Resolve project
if [ -z "$PROJECT" ]; then
  PROJECT=$(gcloud config get-value project 2>/dev/null || true)
  if [ -z "$PROJECT" ]; then
    echo "ERROR: No project set. Use --project or run: gcloud config set project <PROJECT_ID>"
    exit 1
  fi
fi

ZONE="${ZONE:-us-west4-a}"

if [ "$DELETE_ALL" = true ]; then
  echo "Searching for gpu-test* VMs in project $PROJECT..."
  echo ""

  # Find all gpu-test VMs across all zones
  VMS=$(gcloud compute instances list \
    --project="$PROJECT" \
    --filter="name~'^gpu-test'" \
    --format="csv[no-heading](name,zone.basename())" 2>/dev/null)

  if [ -z "$VMS" ]; then
    echo "No gpu-test* VMs found."
    exit 0
  fi

  echo "Found VMs:"
  echo "$VMS" | while IFS=',' read -r name zone; do
    echo "  $name ($zone)"
  done
  echo ""

  echo "$VMS" | while IFS=',' read -r name zone; do
    echo "Deleting $name in $zone..."
    gcloud compute instances delete "$name" \
      --zone="$zone" --project="$PROJECT" --quiet
  done

  echo ""
  echo "All gpu-test VMs deleted."
else
  # Delete a specific VM
  if ! gcloud compute instances describe "$VM_NAME" --zone="$ZONE" --project="$PROJECT" &>/dev/null; then
    echo "VM '$VM_NAME' not found in $ZONE (project: $PROJECT)."
    echo ""
    echo "Check if it's in a different zone:"
    gcloud compute instances list \
      --project="$PROJECT" \
      --filter="name=$VM_NAME" \
      --format="table(name, zone.basename(), status)" 2>/dev/null || true
    exit 1
  fi

  echo "Deleting VM '$VM_NAME' in $ZONE..."
  gcloud compute instances delete "$VM_NAME" \
    --zone="$ZONE" --project="$PROJECT" --quiet

  echo ""
  echo "VM '$VM_NAME' deleted. No more GPU charges."
fi
