# GCP Setup Guide

Before deploying, you must configure your GCP project. The automated script handles everything:

```bash
chmod +x setup-gcp.sh
./setup-gcp.sh
```

Or follow the manual steps below.

## Manual GCP Setup

### 1. Install the Google Cloud SDK

The `gcloud` CLI is the primary tool for managing GCP resources.

```bash
# macOS
brew install google-cloud-sdk

# Linux (Debian/Ubuntu)
sudo apt-get install google-cloud-cli

# Linux (generic)
curl https://sdk.cloud.google.com | bash
exec -l $SHELL   # Restart shell to pick up PATH changes

# Verify
gcloud version
```

After installing gcloud, you also need the **GKE auth plugin**. This plugin is required for `kubectl` to authenticate with GKE clusters. Without it, `kubectl` commands will fail with a `gke-gcloud-auth-plugin was not found` error.

```bash
# Install the GKE auth plugin
gcloud components install gke-gcloud-auth-plugin

# If gcloud was installed via a package manager (brew/apt), use that instead:
# macOS (Homebrew)
brew install google-cloud-sdk && gcloud components install gke-gcloud-auth-plugin
# Linux (Debian/Ubuntu)
sudo apt-get install google-cloud-cli-gke-gcloud-auth-plugin

# Verify
gke-gcloud-auth-plugin --version
```

### 2. Install Terraform, kubectl, and Helm

These three tools are needed alongside gcloud for the deployment.

**Terraform** — Infrastructure-as-code tool that creates the GKE cluster.

```bash
# macOS
brew install terraform

# Linux (Debian/Ubuntu) — add HashiCorp repo first
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install terraform

# Verify
terraform version
```

**kubectl** — Kubernetes CLI for managing workloads in the cluster.

```bash
# Via gcloud (easiest if gcloud is already installed)
gcloud components install kubectl

# macOS
brew install kubectl

# Linux
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/

# Verify
kubectl version --client
```

**Helm** — Kubernetes package manager. KServe, Istio, cert-manager, and OpenClaw are all installed via Helm charts.

```bash
# macOS
brew install helm

# Linux
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Verify
helm version
```

### 3. Authenticate

Two authentications are needed — one for the gcloud CLI itself, and one for Terraform (which uses Application Default Credentials):

```bash
# Authenticate gcloud CLI — opens a browser for Google sign-in
gcloud auth login

# Authenticate for Terraform — creates ~/.config/gcloud/application_default_credentials.json
# Terraform's google provider reads these credentials automatically
gcloud auth application-default login
```

**Why two authentications?** `gcloud auth login` stores credentials that only the `gcloud` CLI uses. Terraform and other SDKs use a separate credential file called Application Default Credentials (ADC). `gcloud auth application-default login` creates this file.

### 4. Create a GCP project

Every GCP resource lives inside a project. Projects have globally unique IDs, their own billing, IAM policies, and API quotas.

```bash
# Create a new project (ID must be globally unique, 6-30 chars, lowercase + digits + hyphens)
gcloud projects create openclaw-kserve-001 --name="OpenClaw KServe"

# Set it as your active project (gcloud remembers this for subsequent commands)
gcloud config set project openclaw-kserve-001

# Verify
gcloud config get-value project
# Output: openclaw-kserve-001
```

**Creating the project under an existing organization:**

If your GCP account belongs to a company or institution (Google Workspace, Cloud Identity), you likely have an organization. Projects created under an org inherit its IAM policies, billing constraints, and security controls.

```bash
# List your organizations
gcloud organizations list
# ID            DISPLAY_NAME       DIRECTORY_CUSTOMER_ID
# 123456789012  My Company Inc     C0xxxxxxx

# List folders within the org (if any — folders are optional sub-groupings)
gcloud resource-manager folders list --organization=123456789012
# ID              DISPLAY_NAME    PARENT
# 111111111111    Engineering     organizations/123456789012
# 222222222222    Research        organizations/123456789012

# Create project directly under the organization
gcloud projects create openclaw-kserve-001 \
  --name="OpenClaw KServe" \
  --organization=123456789012

# OR create project under a specific folder within the org
gcloud projects create openclaw-kserve-001 \
  --name="OpenClaw KServe" \
  --folder=222222222222

# Set as active project
gcloud config set project openclaw-kserve-001
```

**Organization vs no-organization:**

| | No Organization | Under Organization |
|---|---|---|
| **Who** | Personal Gmail accounts | Google Workspace / Cloud Identity |
| **Project location** | Standalone (no parent) | Nested under org or folder |
| **IAM inheritance** | None | Org-level policies apply to all projects |
| **Billing** | Any billing account | May be restricted to org billing accounts |
| **Quotas** | Per-project defaults | May inherit org-level quota overrides |
| **Security** | Self-managed | Org admins can enforce constraints (e.g., allowed regions, required labels) |

**Common issues with org-managed projects:**
- **Organization Policy constraints** may block certain actions (e.g., creating external IPs, using spot VMs, enabling specific APIs). If you get "constraint violated" errors, contact your org admin.
- **Billing restrictions** — some orgs only allow linking to specific billing accounts. Check with your admin if `gcloud billing projects link` fails.
- **Permissions** — you need the `resourcemanager.projects.create` permission on the org or folder. If denied, ask your org admin to create the project for you or grant you the Project Creator role.

**Tip**: Use a dedicated project so you can see all costs in one place and tear everything down cleanly.

### 5. Link a billing account

GCP won't let you create any paid resources (VMs, GPUs, disks) without a billing account linked to the project.

```bash
# List your billing accounts (you need at least one)
gcloud billing accounts list
# ACCOUNT_ID            NAME                 OPEN   MASTER_ACCOUNT_ID
# 0X0X0X-0X0X0X-0X0X0X My Billing Account   True

# If no accounts exist, create one at:
#   https://console.cloud.google.com/billing
# (requires a credit card — won't be charged until free credit runs out)

# Link billing account to your project
gcloud billing projects link openclaw-kserve-001 \
  --billing-account=0X0X0X-0X0X0X-0X0X0X

# Verify
gcloud billing projects describe openclaw-kserve-001
# billingEnabled: true
```

### 6. Enable required APIs

GCP APIs are disabled by default. Each must be explicitly enabled before use.

```bash
# Enable all required APIs at once (~1-2 minutes total)
gcloud services enable \
  compute.googleapis.com \
  container.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  cloudresourcemanager.googleapis.com \
  --project=openclaw-kserve-001

# Verify
gcloud services list --enabled --project=openclaw-kserve-001 --filter="config.name:(compute OR container OR iam)"
```

What each API does:

| API | Purpose |
|-----|---------|
| `compute.googleapis.com` | Compute Engine — VMs, disks, networking. GKE nodes are Compute Engine VMs. |
| `container.googleapis.com` | GKE — create/manage Kubernetes clusters and node pools. |
| `iam.googleapis.com` | IAM — service accounts, roles, permissions. Needed for Workload Identity. |
| `iamcredentials.googleapis.com` | Short-lived service account credentials. Required by Workload Identity. |
| `cloudresourcemanager.googleapis.com` | Project metadata. Terraform needs this to verify the project exists. |

### 7. Check and request GPU quota

**This is the most common blocker for new GCP accounts.** New projects often have a GPU quota of **zero** — you must request an increase before any GPU VMs can be created.

```bash
# Check your L4 GPU quota in us-central1
gcloud compute regions describe us-central1 \
  --project=openclaw-kserve-001 \
  --format=json | grep -A5 '"metric": "NVIDIA_L4_GPUS"'

# Expected output (limit > 0 means you're good):
#   "metric": "NVIDIA_L4_GPUS",
#   "limit": 2.0,
#   "usage": 0.0,
#   "owner": "..."
# If "limit" is missing from the output, the quota is 0.
```

If the limit is 0, request an increase:

1. Go to: https://console.cloud.google.com/iam-admin/quotas
2. Filter by: **Service = "Compute Engine API"**, then search **"NVIDIA L4"**
3. Select **"NVIDIA L4 GPUs"** for region **us-central1**
4. Click **"Edit Quotas"**
5. Request a new limit of **1** (our GPU pool allows max 1 node)
6. Add justification: *"ML model serving for development/testing"*
7. Submit and wait for approval

**Approval times:**
- Established accounts with payment history: minutes to hours
- New accounts with free trial: 24-48 hours
- Some new accounts may need to finish free trial first

**Alternative if quota is denied:**
- Try a different zone (`us-east1-b`, `us-west1-a`, `europe-west4-a`)
- Try a different GPU (`nvidia-tesla-v100` or `nvidia-l4`)
- Start without GPU (cluster + system pool work fine; add GPU later)

### 8. Set default region and zone

```bash
# These defaults are used by gcloud commands that don't specify --region/--zone
gcloud config set compute/region us-central1
gcloud config set compute/zone us-central1-a

# Verify all settings
gcloud config list
```

### 9. Configure Terraform

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Edit `terraform/terraform.tfvars`:

```hcl
project_id = "openclaw-kserve-001"   # Your project ID from step 3
region     = "us-central1"
zone       = "us-central1-a"
```

## GCP Configuration Summary

After completing all steps, verify everything is ready:

```bash
# Authentication
gcloud auth list                              # Shows your active account
ls ~/.config/gcloud/application_default_credentials.json  # ADC for Terraform

# Project
gcloud config get-value project               # openclaw-kserve-001

# Billing
gcloud billing projects describe $(gcloud config get-value project) --format="value(billingEnabled)"
# True

# APIs
gcloud services list --enabled | grep -E "compute|container|iam"
# compute.googleapis.com
# container.googleapis.com
# iam.googleapis.com
# iamcredentials.googleapis.com

# GPU quota
gcloud compute regions describe us-central1 --format=json | grep -A5 '"metric": "NVIDIA_L4_GPUS"'
# "limit": 2.0

# Terraform
cat terraform/terraform.tfvars               # project_id set correctly
```

## Time Estimates

### First-time deployment (end-to-end)

**Local models (llama/qwen): ~25-40 minutes**

| Step | What happens | Time |
|------|-------------|------|
| **GCP setup** (`setup-gcp.sh`) | Auth, create project, enable APIs, check quota | ~3-5 min |
| **GPU quota request** | Google reviews and approves your L4 quota increase | Minutes to 48 hours* |
| **Terraform init** | Downloads the Google provider plugin (~200MB) | ~1-2 min |
| **Terraform apply — GKE cluster** | Provisions the Kubernetes control plane (API server, etcd, scheduler) | **~8-12 min** |
| **Terraform apply — system pool** | Creates 1x e2-standard-2 spot VM, installs kubelet | ~2-3 min |
| **Terraform apply — GPU pool** | Creates pool definition (0 nodes initially, no VM yet) | ~1 min |
| **cert-manager install** | Helm chart + wait for pods Ready | ~1-2 min |
| **Istio install** | 3 Helm charts (base + istiod + gateway) + LoadBalancer IP | ~2-3 min |
| **KServe install** | 2 Helm charts (CRDs + controller) | ~1-2 min |
| **Model deploy — GPU scale-up** | GKE autoscaler provisions g2-standard-4 + L4 spot VM | **~3-5 min** |
| **Model deploy — driver install** | GKE installs NVIDIA GPU drivers on the new node | ~1-2 min |
| **Model deploy — download** | vLLM downloads Llama 3.2 3B from HuggingFace (~6GB) | ~1-3 min |
| **Model deploy — load** | vLLM loads model weights into L4 GPU VRAM | ~1 min |
| **OpenClaw install** | Helm chart + wait for pod Ready | ~1-2 min |
| **Total** | | **~25-40 min** |

**OpenAI API mode: ~10-15 minutes**

| Step | What happens | Time |
|------|-------------|------|
| **GCP setup** (`setup-gcp.sh`) | Auth, create project, enable APIs | ~3-5 min |
| **Terraform** | GKE cluster + system pool (no GPU quota needed) | **~8-12 min** |
| ~~KServe install~~ | *Skipped — not needed for OpenAI API* | — |
| ~~Model deploy~~ | *Skipped — OpenClaw calls OpenAI API directly* | — |
| **OpenClaw install** | Helm chart + wait for pod Ready | ~1-2 min |
| **Total** | | **~10-15 min** |

*GPU quota for new accounts can take 24-48 hours. Established accounts are usually approved within minutes. Not needed for OpenAI mode.

### Subsequent operations

| Operation | Time |
|-----------|------|
| Re-deploy after `terraform destroy` | ~20-30 min (full cycle) |
| Re-deploy model only (GPU already has a node) | ~3-5 min (download + load) |
| Re-deploy model (GPU scaled to zero, needs new node) | ~8-12 min (scale-up + download + load) |
| `terraform destroy` (teardown cluster) | ~5-8 min |
| `gcloud projects delete` (teardown project) | ~10 sec (async, resources stop immediately) |
| Scale GPU to zero (delete InferenceService) | ~5-10 min (node drains and terminates) |
| Helm upgrade (config change, no model reload) | ~1-2 min |

### What takes the longest

The two slowest steps are **GKE cluster creation** (~8-12 min) and **GPU node provisioning** (~3-5 min). Both involve GCP spinning up real VMs, which is why they're slow. Everything else is Helm installs that take 1-3 minutes each.

If the GPU node takes longer than 5 minutes, check for:
- Spot VM capacity issues (the zone may be out of spot L4s — try a different zone)
- Quota exhaustion (`kubectl describe pod -n kserve <pod>` will show "insufficient quota" events)

---

[Back to main README](../README.md)
