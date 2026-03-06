# OpenClaw + KServe on GKE

Deploy [OpenClaw](https://github.com/serhanekicii/openclaw) with a self-hosted Llama 3.2 3B model served via KServe + vLLM on a cost-optimized GKE cluster.

## Architecture

```
Browser / Messaging App
        │
        ▼
OpenClaw Pod (port 18789)                    ← Node.js app, ~512MB RAM
        │  POST /v1/chat/completions
        │  (OpenAI-compatible API)
        ▼
KServe InferenceService                      ← vLLM serving engine
  Llama 3.2 3B Instruct                      ← ~6GB VRAM (FP16)
  (L4 GPU, 24GB VRAM, spot instance)
        │
        ▼
GKE Standard Cluster (us-central1-a, zonal)
  ├─ System pool: e2-standard-2 spot (1-4 nodes) ← Runs everything except the model
  └─ GPU pool: g2-standard-4 + L4 spot (0-1)  ← Scales to zero when idle
```

### How the pieces connect

1. **OpenClaw** is configured with `OPENAI_API_BASE` pointing to the KServe in-cluster Service URL (`http://llama-3-2b-predictor.kserve.svc.cluster.local/v1`). It uses the standard OpenAI SDK to send chat completion requests.

2. **KServe** manages the model lifecycle. When you create an InferenceService, KServe creates a Deployment running vLLM, a Service for routing, and (optionally) Istio VirtualServices for external access.

3. **vLLM** downloads the model from HuggingFace, loads it onto the L4 GPU, and serves an OpenAI-compatible HTTP API. OpenClaw doesn't know or care that it's talking to a local model instead of OpenAI's servers.

4. **GKE cluster autoscaler** manages GPU costs: the GPU node pool is configured with `min=0`, so when no GPU pods exist, the pool scales to zero nodes (no GPU charges). When the InferenceService is created, the autoscaler provisions a GPU node.

## Prerequisites

1. **GCP account** — A Google account (personal Gmail or Workspace). New accounts get **$300 free credit for 90 days**.
2. **CLI tools**: `gcloud`, `terraform`, `kubectl`, `helm`
3. **HuggingFace account**:
   - Accept the [Llama 3.2 3B Instruct license](https://huggingface.co/meta-llama/Llama-3.2-3B-Instruct)
   - Create an [access token](https://huggingface.co/settings/tokens) with "Read" permission

## GCP Configuration (Step 0)

Before deploying, you must configure your GCP project. The automated script handles everything:

```bash
chmod +x setup-gcp.sh
./setup-gcp.sh
```

Or follow the manual steps below.

### Manual GCP Setup

#### 1. Install the Google Cloud SDK

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

#### 2. Install Terraform, kubectl, and Helm

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

#### 3. Authenticate

Two authentications are needed — one for the gcloud CLI itself, and one for Terraform (which uses Application Default Credentials):

```bash
# Authenticate gcloud CLI — opens a browser for Google sign-in
gcloud auth login

# Authenticate for Terraform — creates ~/.config/gcloud/application_default_credentials.json
# Terraform's google provider reads these credentials automatically
gcloud auth application-default login
```

**Why two authentications?** `gcloud auth login` stores credentials that only the `gcloud` CLI uses. Terraform and other SDKs use a separate credential file called Application Default Credentials (ADC). `gcloud auth application-default login` creates this file.

#### 4. Create a GCP project

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

#### 5. Link a billing account

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

#### 6. Enable required APIs

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

#### 7. Check and request GPU quota

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

#### 8. Set default region and zone

```bash
# These defaults are used by gcloud commands that don't specify --region/--zone
gcloud config set compute/region us-central1
gcloud config set compute/zone us-central1-a

# Verify all settings
gcloud config list
```

#### 9. Configure Terraform

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Edit `terraform/terraform.tfvars`:

```hcl
project_id = "openclaw-kserve-001"   # Your project ID from step 3
region     = "us-central1"
zone       = "us-central1-a"
```

### GCP Configuration Summary

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

### First-time deployment (end-to-end): ~25-40 minutes

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

*GPU quota for new accounts can take 24-48 hours. Established accounts are usually approved within minutes.

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

## Quick Start

```bash
# 0. Configure GCP (one-time setup, ~5 min)
chmod +x setup-gcp.sh
./setup-gcp.sh

# 1. Set HuggingFace token (or edit kserve/hf-secret.yaml directly)
export HF_TOKEN=hf_your_token_here

# 2. Deploy everything (~25-40 min)
chmod +x deploy.sh kserve/install-kserve.sh openclaw/install-openclaw.sh
./deploy.sh                # Uses Llama 3.2 3B (default)
# ./deploy.sh --model qwen  # Use Qwen 3.5 2B if Llama license not approved
```

## File-by-File Explanation

### `setup-gcp.sh` — GCP Project Configuration

Interactive script that handles all one-time GCP setup. It:

1. **Authenticates** with Google Cloud (both gcloud CLI and Terraform ADC)
2. **Creates/selects** a GCP project (the organizational unit for all resources)
3. **Links billing** (required before any paid resources can be created)
4. **Enables APIs** (Compute, GKE, IAM, Resource Manager — disabled by default)
5. **Checks GPU quota** (new accounts often have 0 L4 quota — must request increase)
6. **Sets gcloud defaults** (region and zone so you don't pass them every time)
7. **Writes `terraform.tfvars`** automatically (no manual editing needed)
8. **Checks for missing tools** (terraform, kubectl, helm — with install instructions)

Run this once before `deploy.sh`. It's safe to re-run if something failed partway through.

### `terraform/main.tf` — GKE Cluster Infrastructure

Provisions the complete GKE cluster with two node pools. Key design decisions:

| Decision | Choice | Why |
|----------|--------|-----|
| Cluster type | Zonal (single zone) | Free control plane ($0 vs $74.40/mo for regional) |
| System VMs | e2-standard-2 spot | 2 vCPU, 8GB RAM — enough headroom for all system pods |
| GPU VMs | g2-standard-4 + L4 spot | g2 series includes L4 GPU; spot = ~60% savings |
| GPU pool min | 0 nodes | Scale-to-zero eliminates GPU cost when idle |
| GPU taint | `nvidia.com/gpu=present:NoSchedule` | Prevents non-GPU pods from wasting expensive GPU nodes |
| Disk type | pd-standard (HDD) | Cheapest option; SSD not needed for this workload |
| Logging | SYSTEM_COMPONENTS only | Avoids Cloud Logging costs for application logs |

The GPU taint + tolerations pattern is critical for cost control: without it, regular pods could schedule on GPU nodes, preventing scale-to-zero.

### `terraform/variables.tf` — Input Variables

Defines configurable parameters: `project_id` (required), `region`, `zone`, and `cluster_name` (all with defaults).

### `terraform/outputs.tf` — Useful Outputs

Outputs the cluster endpoint and a ready-to-run `gcloud container clusters get-credentials` command that `deploy.sh` uses to configure kubectl.

### `kserve/install-kserve.sh` — KServe Stack Installation

Installs three components in order (each depends on the previous):

1. **cert-manager** (v1.16.3) — Manages TLS certificates automatically. KServe's admission webhook needs TLS certs to validate InferenceService manifests before they're stored in etcd.

2. **Istio** (3 sub-charts) — Service mesh providing the networking layer:
   - `istio-base`: CRDs (VirtualService, Gateway, DestinationRule)
   - `istiod`: Control plane that pushes Envoy config to gateways
   - `istio-ingressgateway`: LoadBalancer for external access to model endpoints

3. **KServe** (v0.14.1, 2 sub-charts) — ML model serving framework:
   - `kserve-crd`: InferenceService CRD definition
   - `kserve controller`: Operator that watches InferenceService resources and creates Deployments, Services, and routing rules

**RawDeployment mode** is used instead of Serverless (Knative) because:
- Avoids installing Knative (significant complexity)
- GPU scale-to-zero is handled at the node level by GKE, not the pod level
- No cold-start latency from model reloading (~2-3 min for 3B model)

### `kserve/hf-secret.yaml` — HuggingFace Token

A Kubernetes Secret template storing your HF token. Llama 3.2 is a gated model — you must accept Meta's license on HuggingFace before the token can download it. The token is injected into the vLLM container as the `HF_TOKEN` environment variable.

### `kserve/llama-inferenceservice.yaml` — Model Deployment

The core KServe resource that deploys the Llama model. Key fields:

| Field | Value | Purpose |
|-------|-------|---------|
| `modelFormat.name` | `huggingface` | Use vLLM backend (OpenAI-compatible) |
| `storageUri` | `hf://meta-llama/Llama-3.2-3B-Instruct` | Download from HuggingFace Hub |
| `args: --max_model_len=8192` | 8192 tokens | Limits KV-cache VRAM usage for efficient inference |
| `nvidia.com/gpu: "1"` | 1 GPU | Claims one L4 exclusively |
| `tolerations` | nvidia.com/gpu taint | Allows scheduling on tainted GPU nodes |
| `nodeSelector: pool: gpu` | GPU pool only | Ensures pod lands on a GPU node |

When applied, this triggers: KServe creates Deployment → pod unschedulable → GKE autoscaler provisions GPU node → drivers install → model downloads → vLLM starts serving.

### `openclaw/values.yaml` — OpenClaw Helm Configuration

Overrides the default Helm chart values to connect OpenClaw to the local model:

| Env Variable | Value | Purpose |
|-------------|-------|---------|
| `OPENAI_API_BASE` | `http://llama-3-2b-predictor.kserve.svc.cluster.local/v1` | KServe in-cluster Service URL |
| `OPENAI_API_KEY` | `dummy` | Required by OpenAI SDK but not validated by vLLM |
| `LLM_MODEL` | `meta-llama/Llama-3.2-3B-Instruct` | Must match vLLM's registered model name |

Also configures a 5Gi PVC for persistent data (conversations, device pairings).

### `openclaw/install-openclaw.sh` — OpenClaw Installation

Creates the namespace, gateway token secret, and Helm release. Uses idempotent patterns (`--dry-run=client | kubectl apply`, `helm upgrade --install`) so it's safe to re-run.

### `deploy.sh` — Master Orchestration Script

Runs all steps sequentially with pre-flight checks:
1. Verifies `gcloud`, `terraform`, `kubectl`, `helm` are installed
2. Checks `terraform.tfvars` exists
3. Handles HF token (from env var or pre-edited file)
4. Runs Terraform → KServe install → model deploy → OpenClaw install
5. Waits up to 10 minutes for the model to become ready

## Manual Step-by-Step

### Step 1: Provision GKE Cluster

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
vim terraform.tfvars  # Set project_id

terraform init     # Download Google provider plugin
terraform plan     # Preview what will be created (optional)
terraform apply    # Create the cluster (~8-12 min)

# Configure kubectl to talk to the new cluster
eval "$(terraform output -raw get_credentials_command)"
cd ..
```

### Step 2: Install KServe

```bash
bash kserve/install-kserve.sh
# Takes ~3-5 minutes
# Verify:
kubectl get pods -n cert-manager    # cert-manager-*, cert-manager-webhook-*
kubectl get pods -n istio-system    # istiod-*, istio-ingressgateway-*
kubectl get pods -n kserve          # kserve-controller-manager-*
```

### Step 3: Deploy the LLM

You have two model options:

| Model | Params | VRAM | Gated? | Notes |
|-------|--------|------|--------|-------|
| **Llama 3.2 3B Instruct** (default) | 3B | ~6GB FP16 | Yes — must accept [Meta license](https://huggingface.co/meta-llama/Llama-3.2-3B-Instruct) | Higher quality, larger community |
| **Qwen 3.5 2B** (alternative) | 2B | ~4GB FP16 | No — open download | No license wait, faster inference, smaller |

**Option A: Llama 3.2 3B (default)**

```bash
# Edit the secret with your HF token
vim kserve/hf-secret.yaml

kubectl apply -f kserve/hf-secret.yaml
kubectl apply -f kserve/llama-inferenceservice.yaml

# Watch the deployment progress
kubectl get inferenceservice -n kserve -w
# Wait for READY=True (may take 5-8 min for GPU node + model download)
```

**Option B: Qwen 3.5 2B (no license required)**

Use this if you can't access Llama (license not approved, gated model issues, etc.).

```bash
# Edit the secret with your HF token (still needed to avoid rate limits)
vim kserve/hf-secret.yaml

kubectl apply -f kserve/hf-secret.yaml
kubectl apply -f kserve/qwen-inferenceservice.yaml    # ← Qwen instead of Llama

# Watch the deployment progress
kubectl get inferenceservice -n kserve -w
# Wait for READY=True
```

**Using deploy.sh with model selection:**

```bash
./deploy.sh                # Default: Llama 3.2 3B
./deploy.sh --model qwen   # Alternative: Qwen 3.5 2B
```

### Step 4: Deploy OpenClaw

```bash
# For Llama (default):
bash openclaw/install-openclaw.sh
# Save the Gateway Token printed at the end!

# For Qwen:
bash openclaw/install-openclaw.sh --values values-qwen.yaml
```

### Step 5: Access OpenClaw

```bash
kubectl port-forward -n openclaw svc/openclaw 18789:18789
# Open http://localhost:18789/?token=YOUR_GATEWAY_TOKEN
# The browser remembers the token after the first access
```

Approve the device pairing:

```bash
kubectl exec -n openclaw deployment/openclaw -c main -- node dist/index.js devices list
kubectl exec -n openclaw deployment/openclaw -c main -- node dist/index.js devices approve <REQUEST_ID>
```

## Verification

```bash
# 1. Check all pods are running
kubectl get pods -n cert-manager
kubectl get pods -n istio-system
kubectl get pods -n kserve
kubectl get pods -n openclaw

# 2. Check the model is ready
kubectl get inferenceservice -n kserve
# NAME         READY   URL
# llama-3-2b   True    http://...

# 3. Test the model endpoint directly
kubectl run curl-test --rm -it --image=curlimages/curl --restart=Never -- \
  curl -s http://llama-3-2b-predictor.kserve.svc.cluster.local/v1/models

# 4. Test a chat completion
kubectl run curl-test --rm -it --image=curlimages/curl --restart=Never -- \
  curl -s -X POST http://llama-3-2b-predictor.kserve.svc.cluster.local/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"meta-llama/Llama-3.2-3B-Instruct","messages":[{"role":"user","content":"Hello!"}],"max_tokens":50}'
```

## Cost Estimates

| Component | Spot $/hr | Spot $/month (24/7) |
|-----------|-----------|---------------------|
| GKE control plane (zonal) | $0.00 | $0.00 |
| e2-standard-2 spot (system) | ~$0.02 | ~$14.60 |
| g2-standard-4 spot (GPU host, includes L4) | ~$0.14 | ~$100.00 |
| pd-standard 80GB total | ~$0.004 | ~$3.20 |
| **Total (GPU running)** | **~$0.17** | **~$118** |
| **Total (GPU scaled to zero)** | **~$0.02** | **~$15** |

All nodes use spot instances. The GPU pool scales to zero when idle.

## Troubleshooting

| Problem | Command | Common Fix |
|---------|---------|-----------|
| GPU node not provisioning | `kubectl describe pod -n kserve <pod>` | Check L4 quota in the zone; try a different zone |
| Model download failing | `kubectl logs -n kserve <pod>` | Verify HF token and license acceptance |
| InferenceService stuck | `kubectl get events -n kserve --sort-by='.lastTimestamp'` | Check resource limits, node taints |
| OpenClaw can't reach model | `kubectl logs -n openclaw <pod>` | Verify OPENAI_API_BASE URL matches the Service name |

## Q&A

### Why does `install-kserve.sh` delete webhooks before installing?

There are two separate webhook deletion steps, each solving a different problem.

**Istio webhook deletion (before `istio-base` install):**

When istiod starts, it continuously reconciles the `istiod-default-validator` ValidatingWebhookConfiguration, claiming server-side apply ownership of fields like `.failurePolicy`. On re-runs, Helm tries to update the same webhook via the `istio-base` chart, but the API server rejects it because istiod's field manager (`pilot-discovery`) owns those fields. Deleting the webhook before the upgrade gives Helm a clean slate — it recreates the webhook with itself as owner. istiod will reconcile it again afterwards, but the Helm install succeeds without conflict.

**KServe webhook deletions (before `kserve-crd` and before `kserve` install):**

*First deletion (before `kserve-crd`):* The kserve-crd chart creates ValidatingWebhookConfigurations that point at the kserve-webhook-server-service. But the webhook server pod comes from the `kserve` chart, which hasn't installed yet. When Helm tries to create ClusterServingRuntime resources, the API server forwards the admission request to the webhook, gets no response (no pod running), and the install fails. Deleting the webhooks removes this chicken-and-egg problem.

*Second deletion (between `kserve-crd` and `kserve`):* The kserve-crd chart just recreated the ModelMesh webhook. cert-manager-cainjector immediately injects its CA bundle into `.clientConfig.caBundle`, claiming server-side apply ownership of that field. When Helm then tries to install the `kserve` chart (which also manages that webhook), it conflicts with cert-manager's field manager. Since we use RawDeployment mode (not ModelMesh), this webhook is unnecessary and safe to delete.

### Why not use Helm annotations to adopt the resources instead of deleting them?

The original approach was to annotate the webhooks with `meta.helm.sh/release-name` and `meta.helm.sh/release-namespace` to tell Helm "this resource belongs to your release." This doesn't work for istiod because pilot-discovery immediately reclaims field ownership after the annotation is set. Deletion is the reliable fix because the controllers (istiod, KServe) recreate their webhooks once they're running — the deletions just create a clean window for Helm to install without field ownership conflicts.

### Why can't `--force` or `--force-replace` fix the conflict?

Helm's `--force` flag (deprecated alias for `--force-replace`) tells Helm to delete and recreate changed resources. However, this flag is incompatible with server-side apply — Helm rejects the combination with the error `"cannot use server-side apply and force replace together"`. The solution is to remove the conflicting resource (the webhook) before the install, rather than trying to force through the conflict.

### Why is the model API URL `http://llama-3-2b-predictor.kserve.svc.cluster.local/v1`?

This is a standard Kubernetes in-cluster DNS name. Each part has a specific origin:

| Part | Meaning |
|------|---------|
| `llama-3-2b` | The InferenceService name (from `metadata.name` in `llama-inferenceservice.yaml`) |
| `-predictor` | KServe appends this — every InferenceService has a "predictor" component (the model server) |
| `.kserve` | The Kubernetes namespace where the InferenceService is deployed |
| `.svc.cluster.local` | Standard K8s DNS suffix for Services (`<service>.<namespace>.svc.cluster.local`) |
| `/v1` | vLLM's OpenAI-compatible API prefix (e.g., `/v1/chat/completions`, `/v1/models`) |

KServe automatically creates a Service named `llama-3-2b-predictor` in the `kserve` namespace, and Kubernetes DNS makes it reachable at that full hostname from any pod in the cluster.

### Where do I get the Gateway Token?

The gateway token authenticates access to the OpenClaw dashboard. Here's how it flows from the install script into the running container:

```
install-openclaw.sh                     # 1. Generates token (or uses $OPENCLAW_GATEWAY_TOKEN)
  └→ kubectl create secret              # 2. Stores it in K8s Secret "openclaw-env-secret"
       └→ values.yaml envFrom:          # 3. Injects secret as env vars into the container
            └→ openclaw.json            # 4. References it via ${OPENCLAW_GATEWAY_TOKEN}
                "auth": {               #    substitution at runtime
                  "mode": "token",
                  "token": "${OPENCLAW_GATEWAY_TOKEN}"
                }
```

There are three ways to set it:

1. **Auto-generated (default):** `install-openclaw.sh` generates a random 32-char hex token via `openssl rand -hex 16` and prints a ready-to-use URL at the end of the install.

2. **Pre-set via environment variable:** Set `OPENCLAW_GATEWAY_TOKEN` before running the install script:
   ```bash
   export OPENCLAW_GATEWAY_TOKEN=my-secret-token
   bash openclaw/install-openclaw.sh
   ```

3. **Via Helm chart:** Pass it directly with `--set gatewayToken=my-secret-token`.

**To access the UI**, pass the token in the URL:

```
http://localhost:18789/?token=YOUR_TOKEN_HERE
```

The browser remembers the token after the first successful access.

**If you lost the token**, retrieve it from the Kubernetes secret:

```bash
kubectl get secret openclaw-env-secret -n openclaw -o jsonpath='{.data.OPENCLAW_GATEWAY_TOKEN}' | base64 -d
```

## Helm Chart (Alternative to Scripts)

The `helm-chart/` directory packages the model + OpenClaw as a single Helm release, making it easier to manage, upgrade, and roll back.

### Usage Examples

```bash
# Basic install (required: hfToken and gatewayToken)
helm install openclaw-stack ./helm-chart \
  --set hfToken=hf_abc123 \
  --set gatewayToken=my-secret-token

# Use the smaller 1B model (less VRAM, faster inference, lower quality)
helm install openclaw-stack ./helm-chart \
  --set hfToken=hf_abc123 \
  --set gatewayToken=my-secret-token \
  --set model.name=meta-llama/Llama-3.2-1B-Instruct \
  --set model.maxModelLen=16384

# Increase context length (needs more GPU VRAM — use A100 or larger)
helm install openclaw-stack ./helm-chart \
  --set hfToken=hf_abc123 \
  --set gatewayToken=my-secret-token \
  --set model.maxModelLen=32768 \
  --set model.resources.limits.memory=32Gi

# Upgrade after changing values (e.g., new model version)
helm upgrade openclaw-stack ./helm-chart \
  --set hfToken=hf_abc123 \
  --set gatewayToken=my-secret-token \
  --set model.name=meta-llama/Llama-3.3-3B-Instruct

# Rollback to previous release
helm rollback openclaw-stack 1

# Uninstall
helm uninstall openclaw-stack
```

### Helm Chart Structure

```
helm-chart/
├── Chart.yaml                          # Chart metadata (name, version)
├── values.yaml                         # Default values (model config, resources)
└── templates/
    ├── hf-secret.yaml                  # HuggingFace token → K8s Secret
    ├── inferenceservice.yaml           # KServe InferenceService (vLLM + Llama)
    ├── openclaw-namespace.yaml         # Namespace for OpenClaw
    └── openclaw-secret.yaml            # Gateway token → K8s Secret
```

## ArgoCD (GitOps Deployment)

For production use, ArgoCD provides continuous GitOps delivery: push to Git → ArgoCD syncs to the cluster automatically.

### Setup

```bash
# 1. Install ArgoCD on the cluster
chmod +x argocd/install-argocd.sh
bash argocd/install-argocd.sh

# 2. Access the ArgoCD UI
kubectl port-forward svc/argocd-server -n argocd 8443:443
# Open https://localhost:8443
# Login with admin / <password printed by install script>

# 3. Update repoURL in argocd/app-of-apps.yaml to YOUR Git repo
vim argocd/app-of-apps.yaml

# 4. Push this repo to Git
git init && git add . && git commit -m "Initial commit"
git remote add origin https://github.com/YOUR_USERNAME/Openclaw-Kserve.git
git push -u origin main

# 5. Bootstrap the app-of-apps
kubectl apply -f argocd/app-of-apps.yaml

# 6. Set secrets (these don't go in Git)
argocd login localhost:8443 --username admin --password '<password>' --insecure
argocd app set openclaw-model \
  --helm-set hfToken=hf_xxx \
  --helm-set gatewayToken=my-secret-token
```

### How ArgoCD Manages the Stack

ArgoCD uses the **app-of-apps pattern**: one parent Application (`openclaw-stack`) that manages child Applications:

```
openclaw-stack (app-of-apps)
  ├── cert-manager       (sync-wave: -4, installs first)
  ├── istio-base         (sync-wave: -3)
  ├── istiod             (sync-wave: -2)
  ├── istio-gateway      (sync-wave: -2)
  ├── kserve-crd         (sync-wave: -1)
  ├── kserve-controller  (sync-wave: -1)
  └── openclaw-model     (sync-wave: 0, installs last)
```

**Sync waves** control installation order (lower number = installed first). This ensures dependencies are met: cert-manager before Istio, Istio before KServe, KServe before the model.

### ArgoCD Features You Get

| Feature | What it does |
|---------|-------------|
| **Auto-sync** | Git push → cluster updates automatically |
| **Self-heal** | Manual `kubectl` changes get reverted to match Git |
| **Pruning** | Resources deleted from Git get deleted from cluster |
| **Rollback** | One-click rollback to any previous Git revision |
| **Diff view** | See exactly what changed before syncing |
| **Health checks** | Visual status of every pod, service, and deployment |

### ArgoCD File Structure

```
argocd/
├── install-argocd.sh      # Script to install ArgoCD itself
├── app-of-apps.yaml       # Parent Application (bootstrap this first)
└── apps/
    ├── cert-manager.yaml  # Child app: cert-manager Helm chart
    ├── istio.yaml         # Child app: Istio (base + istiod + gateway)
    ├── kserve.yaml        # Child app: KServe (CRDs + controller)
    └── openclaw-stack.yaml # Child app: Our custom Helm chart
```

### Day-2 Operations with ArgoCD

```bash
# Change the model — edit helm-chart/values.yaml, commit, push:
#   ArgoCD detects the change and syncs automatically

# Scale down GPU (stop paying for it):
#   Delete the InferenceService from Git → ArgoCD removes it → GPU scales to 0

# View sync status:
argocd app list
argocd app get openclaw-stack

# Force sync (don't wait for poll interval):
argocd app sync openclaw-stack

# View diff before syncing:
argocd app diff openclaw-stack
```

## Stop and Start

Use `stop.sh` and `start.sh` to pause and resume the cluster without a full teardown/redeploy cycle.

### Stopping

```bash
./stop.sh              # Stop GPU only — delete model, system pool stays (~$0.02/hr)
./stop.sh --all        # Stop everything — resize all pools to 0 nodes (~$0.00/hr)
./stop.sh --destroy    # Destroy cluster entirely via Terraform ($0.00, needs full redeploy)
```

### Restarting

```bash
./start.sh              # Redeploy model only (after stop.sh)
./start.sh --all        # Restart nodes + redeploy model (after stop.sh --all)
./start.sh --model qwen # Restart with Qwen instead of Llama
```

### Stop/start comparison

| Command | What happens | Hourly cost | Restart time |
|---------|-------------|-------------|-------------|
| `./stop.sh` | Model deleted, GPU scales to 0, system pool stays | ~$0.02 | ~5-10 min |
| `./stop.sh --all` | All node pools resized to 0, control plane stays (free) | ~$0.00 | ~5-10 min |
| `./stop.sh --destroy` | Cluster deleted entirely via Terraform | $0.00 | ~25-40 min (full deploy.sh) |

### Typical daily workflow

```bash
# Morning: start working
./start.sh                  # GPU node provisions, model loads (~5-10 min)

# Evening: done for the day
./stop.sh                   # GPU stops, saves ~$0.15/hr GPU cost

# Weekend: not using it at all
./stop.sh --all             # Everything stops, saves ~$0.17/hr

# Monday: back to work
./start.sh --all            # Nodes + model restart (~5-10 min)
```

### How stop --all works

When you run `./stop.sh --all`, the script:

1. Deletes all InferenceServices (model pods stop, GPU node drains)
2. Resizes `system-pool` to 0 nodes via `gcloud container clusters resize`
3. Resizes `gpu-pool` to 0 nodes

The GKE **control plane keeps running** (free for zonal clusters). All Kubernetes state is preserved — namespaces, secrets, Helm releases, ConfigMaps. They're stored in etcd on the control plane, not on worker nodes.

When you run `./start.sh --all`:

1. Resizes `system-pool` back to 1 node
2. Waits for the node to become Ready
3. Waits for system pods (Istio, KServe controller) to reschedule
4. Re-applies the InferenceService (GPU node scales up, model loads)
5. OpenClaw pod reschedules automatically and reconnects to the model

## Teardown

There are multiple levels of teardown depending on how much you want to remove.

### Option 1: Stop GPU costs only (keep everything else)

Remove the InferenceService so the GPU node scales to zero. The cluster, KServe, and OpenClaw stay running. You can re-apply the InferenceService later to bring the model back.

```bash
# Delete the model — GPU node pool scales to 0 within ~10 min
kubectl delete inferenceservice llama-3-2b -n kserve

# Verify GPU node is gone
kubectl get nodes -l pool=gpu
# No resources found

# Cost after this: ~$0.02/hr (system pool only)
```

To bring the model back:
```bash
kubectl apply -f kserve/llama-inferenceservice.yaml
```

### Option 2: Delete all workloads (keep the cluster)

Remove OpenClaw, the model, and KServe but keep the GKE cluster for other use.

```bash
# Delete OpenClaw
helm uninstall openclaw -n openclaw
kubectl delete namespace openclaw

# Delete model and KServe
kubectl delete inferenceservice llama-3-2b -n kserve
helm uninstall kserve -n kserve
helm uninstall kserve-crd -n kserve
kubectl delete namespace kserve

# Delete Istio
helm uninstall istio-ingressgateway -n istio-system
helm uninstall istiod -n istio-system
helm uninstall istio-base -n istio-system
kubectl delete namespace istio-system

# Delete cert-manager
helm uninstall cert-manager -n cert-manager
kubectl delete namespace cert-manager

# If using ArgoCD:
argocd app delete openclaw-stack --cascade  # Deletes all child apps
helm uninstall argocd -n argocd
kubectl delete namespace argocd

# Cost after this: ~$0.02/hr (empty system pool)
```

### Option 3: Delete the GKE cluster (keep the GCP project)

Destroy all Terraform-managed infrastructure. This deletes the cluster, all node pools, all workloads, and all persistent disks.

```bash
cd terraform
terraform destroy
# Type "yes" when prompted

# Verify — should show no clusters
gcloud container clusters list --project=$(terraform output -raw cluster_name 2>/dev/null || cat terraform.tfvars | grep project_id | cut -d'"' -f2)

# Cost after this: $0.00/hr (nothing running)
```

To redeploy from scratch later:
```bash
./deploy.sh
```

### Option 4: Delete the entire GCP project (nuclear option)

This is the cleanest teardown — it deletes the project and **everything inside it**: the cluster, all VMs, disks, networking, IAM policies, and API configurations. Nothing survives. Billing stops immediately.

```bash
# First, check what project you're about to delete
gcloud config get-value project
# openclaw-kserve-001

# Delete the project
gcloud projects delete openclaw-kserve-001

# You will be prompted to confirm. Type the project ID again.
```

**Important details about project deletion:**

- **30-day recovery window**: GCP doesn't delete the project immediately. It enters a "pending deletion" state for 30 days, during which you can restore it:
  ```bash
  # Restore a project within the 30-day window
  gcloud projects undelete openclaw-kserve-001
  ```
  After 30 days, the project and all data are permanently destroyed.

- **Billing stops immediately**: Even though the project isn't fully deleted for 30 days, you stop being charged as soon as you run the delete command. All resources are shut down.

- **Project ID is reserved**: The globally unique project ID cannot be reused by anyone (including you) even after the project is permanently deleted. Choose a new ID if you recreate.

- **Organization-managed projects**: If the project was created under an organization, you need the `resourcemanager.projects.delete` permission on the project. Org admins may have restricted this. If denied:
  ```bash
  # Check who can delete projects in your org
  gcloud projects get-iam-policy openclaw-kserve-001 \
    --format="table(bindings.role, bindings.members)" \
    --filter="bindings.role:roles/resourcemanager.projectDeleter OR bindings.role:roles/owner"
  ```

- **Terraform state**: If you delete the project via `gcloud` instead of `terraform destroy`, Terraform's state file will be out of sync. Clean it up:
  ```bash
  # Remove stale state after manual project deletion
  cd terraform
  rm -f terraform.tfstate terraform.tfstate.backup
  ```

### Teardown comparison

| Method | What's deleted | Recovery | Time to $0 cost |
|--------|---------------|----------|-----------------|
| Delete InferenceService | Model pod + GPU node | Re-apply YAML | ~10 min |
| Helm uninstall all | All workloads | Re-run deploy.sh | ~5 min |
| `terraform destroy` | Cluster + nodes + disks | Re-run deploy.sh (~15 min) | Immediate |
| `gcloud projects delete` | Everything in the project | `gcloud projects undelete` within 30 days | Immediate |
