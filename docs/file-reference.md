# File Reference

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

### `openclaw/values*.yaml` — OpenClaw Helm Configuration

Composable values files — model configs and skills are separate so you can mix and match:

| File | Purpose | GPU needed | API key needed |
|------|---------|-----------|----------------|
| `values.yaml` | Llama 3.2 3B via KServe vLLM | Yes | No |
| `values-qwen.yaml` | Qwen 3.5 2B via KServe vLLM | Yes | No |
| `values-openai.yaml` | OpenAI API (gpt-4o-mini) | No | Yes (`OPENAI_API_KEY`) |
| `values-skills.yaml` | ClawHub skills overlay | — | — |

**Model files** configure `openclaw.json` via the `configMaps.config` section with:
- Gateway auth (token mode, `${OPENCLAW_GATEWAY_TOKEN}` env substitution)
- Model provider(s) with baseUrl, API type, and model list
- Default agent model
- 5Gi PVC for persistent data (conversations, device pairings)

**`values-skills.yaml`** is a composable overlay that adds an `init-skills` init container and persistence mounts. Apply it alongside any model file — Helm deep-merges multiple `-f` files left-to-right.

Usage:
```bash
# Local Llama model (default)
bash openclaw/install-openclaw.sh

# Local Qwen model
bash openclaw/install-openclaw.sh --values values-qwen.yaml

# OpenAI API (no GPU needed)
export OPENAI_API_KEY=sk-...
bash openclaw/install-openclaw.sh --values values-openai.yaml

# Any model + skills (compose with values-skills.yaml)
bash openclaw/install-openclaw.sh --values values.yaml --values values-skills.yaml
bash openclaw/install-openclaw.sh --values values-qwen.yaml --values values-skills.yaml
```

### `openclaw/install-openclaw.sh` — OpenClaw Installation

Creates the namespace, gateway token secret (optionally including `OPENAI_API_KEY` if set), and Helm release. Accepts one or more `--values` flags — Helm deep-merges them left-to-right, so overlays like `values-skills.yaml` should come after the base model file. Uses idempotent patterns (`--dry-run=client | kubectl apply`, `helm upgrade --install`) so it's safe to re-run.

### `deploy.sh` — Master Orchestration Script

Runs all steps sequentially with pre-flight checks:
1. Verifies `gcloud`, `terraform`, `kubectl`, `helm` are installed
2. Checks `terraform.tfvars` exists
3. Handles HF token (from env var or pre-edited file)
4. Runs Terraform → KServe install → model deploy → OpenClaw install
5. Waits up to 10 minutes for the model to become ready

For OpenAI mode, steps 2 (KServe) and 3 (model deploy) are skipped entirely — OpenClaw calls the OpenAI API directly, so cert-manager, Istio, and KServe are not installed. This saves ~3-5 min deploy time and ~500MB RAM on the system pool.

Flags:
- `--model llama|qwen|openai` — Select the model backend (default: interactive prompt)
- `--skills` — Enable ClawHub skill installation (applies `values-skills.yaml`)

---

[Back to main README](../README.md)
