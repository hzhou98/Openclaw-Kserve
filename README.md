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
  (T4 GPU, 16GB VRAM, spot instance)
        │
        ▼
GKE Standard Cluster (us-central1-a, zonal)
  ├─ System pool: e2-medium spot (1-3 nodes) ← Runs everything except the model
  └─ GPU pool: n1-standard-4 + T4 spot (0-2) ← Scales to zero when idle
```

### How the pieces connect

1. **OpenClaw** is configured with `OPENAI_API_BASE` pointing to the KServe in-cluster Service URL (`http://llama-3-2b-predictor.kserve.svc.cluster.local/v1`). It uses the standard OpenAI SDK to send chat completion requests.

2. **KServe** manages the model lifecycle. When you create an InferenceService, KServe creates a Deployment running vLLM, a Service for routing, and (optionally) Istio VirtualServices for external access.

3. **vLLM** downloads the model from HuggingFace, loads it onto the T4 GPU, and serves an OpenAI-compatible HTTP API. OpenClaw doesn't know or care that it's talking to a local model instead of OpenAI's servers.

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

#### 2. Authenticate

Two authentications are needed — one for the gcloud CLI itself, and one for Terraform (which uses Application Default Credentials):

```bash
# Authenticate gcloud CLI — opens a browser for Google sign-in
gcloud auth login

# Authenticate for Terraform — creates ~/.config/gcloud/application_default_credentials.json
# Terraform's google provider reads these credentials automatically
gcloud auth application-default login
```

**Why two authentications?** `gcloud auth login` stores credentials that only the `gcloud` CLI uses. Terraform and other SDKs use a separate credential file called Application Default Credentials (ADC). `gcloud auth application-default login` creates this file.

#### 3. Create a GCP project

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

#### 4. Link a billing account

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

#### 5. Enable required APIs

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

#### 6. Check and request GPU quota

**This is the most common blocker for new GCP accounts.** New projects often have a GPU quota of **zero** — you must request an increase before any GPU VMs can be created.

```bash
# Check your T4 GPU quota in us-central1
gcloud compute regions describe us-central1 \
  --project=openclaw-kserve-001 \
  --format=json | grep -A3 NVIDIA_T4_GPUS

# Expected output (limit > 0 means you're good):
#   "metric": "NVIDIA_T4_GPUS",
#   "limit": 2.0,
#   "usage": 0.0
```

If the limit is 0, request an increase:

1. Go to: https://console.cloud.google.com/iam-admin/quotas
2. Filter by: **Service = "Compute Engine API"**, then search **"NVIDIA T4"**
3. Select **"NVIDIA T4 GPUs"** for region **us-central1**
4. Click **"Edit Quotas"**
5. Request a new limit of **2** (our GPU pool allows max 2 nodes)
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

#### 7. Set default region and zone

```bash
# These defaults are used by gcloud commands that don't specify --region/--zone
gcloud config set compute/region us-central1
gcloud config set compute/zone us-central1-a

# Verify all settings
gcloud config list
```

#### 8. Configure Terraform

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
gcloud compute regions describe us-central1 --format=json | grep -A3 NVIDIA_T4_GPUS
# "limit": 2.0

# Terraform
cat terraform/terraform.tfvars               # project_id set correctly
```

## Quick Start

```bash
# 0. Configure GCP (one-time setup, ~5 min)
chmod +x setup-gcp.sh
./setup-gcp.sh

# 1. Set HuggingFace token (or edit kserve/hf-secret.yaml directly)
export HF_TOKEN=hf_your_token_here

# 2. Deploy everything (~15-25 min)
chmod +x deploy.sh kserve/install-kserve.sh openclaw/install-openclaw.sh
./deploy.sh
```

## File-by-File Explanation

### `setup-gcp.sh` — GCP Project Configuration

Interactive script that handles all one-time GCP setup. It:

1. **Authenticates** with Google Cloud (both gcloud CLI and Terraform ADC)
2. **Creates/selects** a GCP project (the organizational unit for all resources)
3. **Links billing** (required before any paid resources can be created)
4. **Enables APIs** (Compute, GKE, IAM, Resource Manager — disabled by default)
5. **Checks GPU quota** (new accounts often have 0 T4 quota — must request increase)
6. **Sets gcloud defaults** (region and zone so you don't pass them every time)
7. **Writes `terraform.tfvars`** automatically (no manual editing needed)
8. **Checks for missing tools** (terraform, kubectl, helm — with install instructions)

Run this once before `deploy.sh`. It's safe to re-run if something failed partway through.

### `terraform/main.tf` — GKE Cluster Infrastructure

Provisions the complete GKE cluster with two node pools. Key design decisions:

| Decision | Choice | Why |
|----------|--------|-----|
| Cluster type | Zonal (single zone) | Free control plane ($0 vs $74.40/mo for regional) |
| System VMs | e2-medium spot | Cheapest burstable VM that fits all system pods |
| GPU VMs | n1-standard-4 + T4 spot | Minimum machine type for T4 attachment; spot = ~60% savings |
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
| `args: --max_model_len=8192` | 8192 tokens | Limits KV-cache VRAM usage to fit T4's 16GB |
| `nvidia.com/gpu: "1"` | 1 GPU | Claims one T4 exclusively |
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

### Step 3: Deploy Llama 3.2 3B

```bash
# Edit the secret with your HF token
vim kserve/hf-secret.yaml

kubectl apply -f kserve/hf-secret.yaml
kubectl apply -f kserve/llama-inferenceservice.yaml

# Watch the deployment progress
kubectl get inferenceservice -n kserve -w
# Wait for READY=True (may take 5-8 min for GPU node + model download)
```

### Step 4: Deploy OpenClaw

```bash
bash openclaw/install-openclaw.sh
# Save the Gateway Token printed at the end!
```

### Step 5: Access OpenClaw

```bash
kubectl port-forward -n openclaw svc/openclaw 18789:18789
# Open http://localhost:18789
# Enter your Gateway Token and click Connect
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
| e2-medium spot (system) | ~$0.01 | ~$7.30 |
| n1-standard-4 spot (GPU host) | ~$0.04 | ~$28.80 |
| T4 GPU spot | ~$0.11 | ~$80.00 |
| pd-standard 80GB total | ~$0.004 | ~$3.20 |
| **Total (GPU running)** | **~$0.16** | **~$119** |
| **Total (GPU scaled to zero)** | **~$0.01** | **~$10** |

All nodes use spot instances. The GPU pool scales to zero when idle.

## Troubleshooting

| Problem | Command | Common Fix |
|---------|---------|-----------|
| GPU node not provisioning | `kubectl describe pod -n kserve <pod>` | Check T4 quota in the zone; try a different zone |
| Model download failing | `kubectl logs -n kserve <pod>` | Verify HF token and license acceptance |
| InferenceService stuck | `kubectl get events -n kserve --sort-by='.lastTimestamp'` | Check resource limits, node taints |
| OpenClaw can't reach model | `kubectl logs -n openclaw <pod>` | Verify OPENAI_API_BASE URL matches the Service name |

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

## Teardown

```bash
# Delete everything (cluster + all workloads)
cd terraform
terraform destroy

# Or just delete workloads but keep the cluster:
kubectl delete inferenceservice llama-3-2b -n kserve   # Stops GPU cost
helm uninstall openclaw -n openclaw

# If using ArgoCD:
argocd app delete openclaw-stack --cascade  # Deletes all child apps too
```
