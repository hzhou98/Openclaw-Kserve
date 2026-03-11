# Manual Step-by-Step Deployment

> For the automated deployment, use `./deploy.sh`. This guide walks through each step manually.

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

### Step 2: Install KServe (skip for OpenAI mode)

If using OpenAI API, skip this step entirely and go to Step 4.

```bash
bash kserve/install-kserve.sh
# Takes ~3-5 minutes
# Verify:
kubectl get pods -n cert-manager    # cert-manager-*, cert-manager-webhook-*
kubectl get pods -n istio-system    # istiod-*, istio-ingressgateway-*
kubectl get pods -n kserve          # kserve-controller-manager-*
```

### Step 3: Deploy the LLM (skip for OpenAI mode)

If using OpenAI API, skip this step and go to Step 4. You have two model options:

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
./deploy.sh                         # Default: Llama 3.2 3B
./deploy.sh --model qwen            # Alternative: Qwen 3.5 2B
./deploy.sh --model llama --skills  # Llama + ClawHub skills
./deploy.sh --model qwen --skills   # Qwen + ClawHub skills
```

### Step 4: Deploy OpenClaw

```bash
# For Llama (default):
bash openclaw/install-openclaw.sh
# Save the Gateway Token printed at the end!

# For Qwen:
bash openclaw/install-openclaw.sh --values values-qwen.yaml

# For OpenAI API (no GPU needed):
export OPENAI_API_KEY=sk-...
bash openclaw/install-openclaw.sh --values values-openai.yaml

# Any model + skills (compose multiple --values):
bash openclaw/install-openclaw.sh --values values.yaml --values values-skills.yaml
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

---

See the [main README](../README.md) for the full project overview, architecture, and automated deployment instructions.
