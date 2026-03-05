# =============================================================================
# GKE Cluster Configuration for OpenClaw + KServe
# =============================================================================
#
# This Terraform config creates a cost-optimized GKE Standard cluster with
# two node pools:
#
#   1. System pool (e2-medium, spot) - Runs Kubernetes system components,
#      KServe controller, Istio, cert-manager, and the OpenClaw application.
#      Always has at least 1 node running.
#
#   2. GPU pool (n1-standard-4 + T4, spot) - Runs the Llama 3.2 3B model
#      via vLLM. Scales to zero when no GPU workloads are scheduled, so you
#      only pay when the model is actually serving.
#
# Key cost decisions:
#   - Zonal cluster (single zone) = free GKE control plane (vs $74/mo regional)
#   - Spot VMs = 60-91% cheaper than on-demand (but can be preempted)
#   - Minimal logging/monitoring = avoids Cloud Logging/Monitoring charges
#   - pd-standard disks = cheapest persistent disk option
#   - GPU scale-to-zero = no GPU cost when idle
#
# Estimated costs:
#   - Idle (no GPU):  ~$5-7/month  (1x e2-medium spot ~$7.30/mo)
#   - GPU 24/7:       ~$100/month  (spot T4 ~$110/mo + system node)
#   - GPU 8hrs/day:   ~$35-40/month
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

# -----------------------------------------------------------------------------
# Enable required GCP APIs
# -----------------------------------------------------------------------------
# These APIs must be enabled before any GKE resources can be created.
# - container.googleapis.com: GKE API (creating/managing clusters)
# - compute.googleapis.com: Compute Engine API (VMs, disks, networking)
#
# disable_on_destroy = false prevents Terraform from disabling these APIs
# when you run `terraform destroy`, which avoids breaking other resources
# in the project that may depend on them.
# -----------------------------------------------------------------------------
resource "google_project_service" "apis" {
  for_each = toset([
    "container.googleapis.com",
    "compute.googleapis.com",
  ])
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# -----------------------------------------------------------------------------
# GKE Cluster
# -----------------------------------------------------------------------------
# Creates a GKE Standard (not Autopilot) cluster. Standard is chosen because:
#   - Autopilot doesn't support GPU taints/tolerations as flexibly
#   - Standard allows scale-to-zero GPU node pools
#   - Standard gives full control over machine types and spot configuration
#
# The cluster is "zonal" (location = a single zone like us-central1-a) rather
# than "regional" (location = us-central1). Zonal clusters have a free control
# plane but offer no control-plane HA. Regional clusters cost $74.40/mo for
# the control plane. For a dev/personal deployment, zonal is fine.
#
# remove_default_node_pool + initial_node_count = 1:
#   GKE requires at least one node pool at creation time, but we want to
#   manage our own pools separately. This creates a temporary default pool
#   with 1 node, then immediately deletes it. Our custom pools (system, gpu)
#   are created as separate resources below.
# -----------------------------------------------------------------------------
resource "google_container_cluster" "primary" {
  name     = var.cluster_name
  location = var.zone

  # Remove the default node pool immediately after cluster creation.
  # We define our own node pools below for full control over config.
  remove_default_node_pool = true
  initial_node_count       = 1

  # REGULAR release channel: receives GKE updates after RAPID channel,
  # providing a balance of new features and stability. This ensures
  # the cluster stays on a supported Kubernetes version automatically.
  release_channel {
    channel = "REGULAR"
  }

  # Workload Identity federates Kubernetes service accounts with GCP IAM.
  # This is the recommended way for pods to authenticate to GCP services
  # (instead of storing service account JSON keys as secrets).
  # Format: <project-id>.svc.id.goog
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Only collect logs/metrics for Kubernetes system components (kubelet,
  # kube-proxy, etc.), not for application workloads. This significantly
  # reduces Cloud Logging and Cloud Monitoring costs. Application logs
  # can still be viewed via `kubectl logs`.
  logging_config {
    enable_components = ["SYSTEM_COMPONENTS"]
  }
  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
  }

  # Network policies (Calico-based firewall rules between pods) are disabled
  # to reduce resource overhead. Not needed for this simple deployment.
  network_policy {
    enabled = false
  }

  # Wait for the GCP APIs to be enabled before creating the cluster.
  depends_on = [google_project_service.apis]
}

# -----------------------------------------------------------------------------
# System Node Pool
# -----------------------------------------------------------------------------
# Runs all non-GPU workloads: Kubernetes system pods, Istio, cert-manager,
# KServe controller, and the OpenClaw application pod.
#
# e2-medium: 2 vCPUs, 4GB RAM. The smallest machine type that can comfortably
# run all system components. Shared-core (burstable) which keeps costs low.
#
# Spot VMs: Up to 91% cheaper than on-demand, but GCP can reclaim them with
# 30 seconds notice. For a dev cluster this is acceptable. GKE will
# automatically reschedule pods when a spot VM is preempted.
#
# Autoscaling 1-3 nodes: Always keeps at least 1 node (so the cluster is
# functional), but can scale up to 3 if pod resource requests exceed what
# a single node can provide (e.g., during Istio + KServe initial install).
# -----------------------------------------------------------------------------
resource "google_container_node_pool" "system" {
  name     = "system-pool"
  location = var.zone
  cluster  = google_container_cluster.primary.name

  autoscaling {
    min_node_count = 1
    max_node_count = 3
  }

  node_config {
    machine_type = "e2-medium"
    spot         = true
    disk_size_gb = 30       # 30GB is enough for system workloads
    disk_type    = "pd-standard"  # HDD-backed, cheapest option (~$0.04/GB/mo)

    # Broad OAuth scope; fine-grained access is controlled via IAM and
    # Workload Identity, not OAuth scopes.
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    # Required for Workload Identity to function. Tells the node to use
    # the GKE metadata server instead of the default Compute Engine one.
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    # Label for nodeSelector. OpenClaw pods don't need a nodeSelector since
    # they'll naturally avoid GPU nodes (due to the taint), but this label
    # allows explicit targeting if needed.
    labels = {
      pool = "system"
    }
  }

  management {
    auto_repair  = true   # Replace unhealthy nodes automatically
    auto_upgrade = true   # Keep node OS and kubelet version current
  }
}

# -----------------------------------------------------------------------------
# GPU Node Pool
# -----------------------------------------------------------------------------
# Runs the Llama 3.2 3B model served by vLLM via KServe.
#
# n1-standard-4: 4 vCPUs, 15GB RAM. Required minimum for T4 GPU attachment.
# The model itself uses ~6GB GPU VRAM + ~8GB system RAM for the vLLM process.
#
# nvidia-tesla-t4: 16GB VRAM, good price/performance for inference.
# Llama 3.2 3B in FP16 needs ~6GB VRAM, fitting easily in the T4's 16GB.
# The --max_model_len=8192 in the InferenceService keeps KV-cache within
# the remaining ~10GB VRAM.
#
# gpu_driver_installation_config: Tells GKE to automatically install the
# NVIDIA GPU driver on these nodes. Without this, you'd need to manually
# deploy the NVIDIA device plugin DaemonSet.
#
# Taint (nvidia.com/gpu=present:NoSchedule):
#   Prevents non-GPU pods from scheduling on expensive GPU nodes. Only pods
#   with a matching toleration (like our InferenceService) will be placed
#   here. This ensures the GPU pool can scale to zero when no GPU workloads
#   exist — the cluster autoscaler removes nodes with no scheduled pods.
#
# Scale-to-zero (min_node_count = 0):
#   When no pods need a GPU (e.g., if you delete the InferenceService),
#   GKE cluster autoscaler will scale this pool to 0 nodes. This means
#   zero GPU cost when idle. When a GPU pod is created, the autoscaler
#   provisions a new node (~2-5 min startup time).
# -----------------------------------------------------------------------------
resource "google_container_node_pool" "gpu" {
  name     = "gpu-pool"
  location = var.zone
  cluster  = google_container_cluster.primary.name

  autoscaling {
    min_node_count = 0    # Scale to zero when no GPU workloads exist
    max_node_count = 2    # Allow up to 2 GPU nodes for headroom
  }

  node_config {
    machine_type = "n1-standard-4"  # 4 vCPU, 15GB RAM — minimum for T4
    spot         = true
    disk_size_gb = 50       # Extra space for model download cache
    disk_type    = "pd-standard"

    guest_accelerator {
      type  = "nvidia-tesla-t4"   # 16GB VRAM, ~$0.11/hr spot
      count = 1                    # 1 GPU per node
      gpu_driver_installation_config {
        gpu_driver_version = "LATEST"  # GKE auto-installs NVIDIA drivers
      }
    }

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    labels = {
      pool = "gpu"  # Used by nodeSelector in InferenceService manifest
    }

    # Taint ensures ONLY pods that explicitly tolerate GPU scheduling land
    # here. Without this taint, regular system pods could fill GPU nodes,
    # preventing scale-to-zero and wasting money.
    taint {
      key    = "nvidia.com/gpu"
      value  = "present"
      effect = "NO_SCHEDULE"
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}
