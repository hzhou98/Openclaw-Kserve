# Adding Custom Models

Deploy any HuggingFace model on KServe + vLLM. You need two files:

1. **KServe InferenceService** — tells KServe which model to serve
2. **OpenClaw values file** — tells OpenClaw how to connect to it

## Quick Start

```bash
# 1. Copy the templates
cp kserve/example-inferenceservice.yaml kserve/mistral-inferenceservice.yaml
cp openclaw/example-values.yaml openclaw/values-mistral.yaml

# 2. Edit both files (see sections below)

# 3. Deploy
kubectl apply -f kserve/hf-secret.yaml
kubectl apply -f kserve/mistral-inferenceservice.yaml
bash openclaw/install-openclaw.sh --values openclaw/values-mistral.yaml

# 4. (Optional) Add skills
bash openclaw/install-openclaw.sh \
  --values openclaw/values-mistral.yaml \
  --values openclaw/values-skills.yaml
```

## Step 1: Create the InferenceService

Copy `kserve/example-inferenceservice.yaml` and change three things:

| Field | What to change | Example |
|-------|---------------|---------|
| `metadata.name` | DNS-safe name (lowercase, hyphens) | `mistral-7b` |
| `args[0]` (`--model=`) | HuggingFace model ID | `mistralai/Mistral-7B-Instruct-v0.3` |
| `args[1]` (`--max_model_len=`) | Max sequence length | `4096` for 7B models |

### Example: Mistral 7B

```yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: mistral-7b
  namespace: kserve
spec:
  predictor:
    model:
      modelFormat:
        name: huggingface
      runtime: kserve-huggingfaceserver
      env:
        - name: HF_TOKEN
          valueFrom:
            secretKeyRef:
              name: hf-secret
              key: HF_TOKEN
      args:
        - "--model=mistralai/Mistral-7B-Instruct-v0.3"
        - "--max_model_len=4096"
      resources:
        limits:
          cpu: "4"
          memory: 16Gi
          nvidia.com/gpu: "1"
        requests:
          cpu: "2"
          memory: 8Gi
          nvidia.com/gpu: "1"
    tolerations:
      - key: nvidia.com/gpu
        operator: Equal
        value: present
        effect: NoSchedule
    nodeSelector:
      pool: gpu
```

## Step 2: Create the OpenClaw Values File

Copy `openclaw/example-values.yaml` and change three things:

| Field | What to change | Example |
|-------|---------------|---------|
| `baseUrl` | `http://<isvc-name>-predictor.kserve.svc.cluster.local/v1` | `http://mistral-7b-predictor.kserve.svc.cluster.local/v1` |
| `models[].id` | Must exactly match the HuggingFace model ID | `mistralai/Mistral-7B-Instruct-v0.3` |
| `agents.defaults.model.primary` | `kserve-vllm/<model-id>` | `kserve-vllm/mistralai/Mistral-7B-Instruct-v0.3` |

The `baseUrl` follows the pattern: `http://<metadata.name>-predictor.kserve.svc.cluster.local/v1`

The `models[].id` **must exactly match** what vLLM reports via `GET /v1/models` — this is the HuggingFace model ID by default.

## Compatible Models (NVIDIA L4, 24GB VRAM)

| Model | HuggingFace ID | VRAM | Gated? | Notes |
|-------|---------------|------|--------|-------|
| Llama 3.2 1B | `meta-llama/Llama-3.2-1B-Instruct` | ~2GB | Yes | Smallest Llama, fast |
| Llama 3.2 3B | `meta-llama/Llama-3.2-3B-Instruct` | ~6GB | Yes | Default in this project |
| Qwen 3.5 2B | `Qwen/Qwen3.5-2B` | ~4GB | No | Good quality for size |
| Qwen 2.5 7B | `Qwen/Qwen2.5-7B-Instruct` | ~14GB | No | Strong 7B model |
| Mistral 7B v0.3 | `mistralai/Mistral-7B-Instruct-v0.3` | ~14GB | No | Popular open model |
| Gemma 2 2B | `google/gemma-2-2b-it` | ~4GB | No | Google's small model |
| Gemma 2 9B | `google/gemma-2-9b-it` | ~18GB | No | Fits tight on L4 |
| Phi 3.5 Mini | `microsoft/Phi-3.5-mini-instruct` | ~8GB | No | Microsoft, good reasoning |
| TinyLlama 1.1B | `TinyLlama/TinyLlama-1.1B-Chat-v1.0` | ~2GB | No | Very fast, lower quality |

**VRAM rule of thumb**: 1B parameters ≈ 2GB VRAM (FP16), plus KV-cache overhead.

Models larger than ~14GB need `--max_model_len` reduced (e.g., `4096`) to leave room for KV-cache.

### Gated Models

Some models (Llama, etc.) require:
1. Accept the license on the model's HuggingFace page
2. Wait for approval (usually instant)
3. Use an HF token with "Read" permission

Open models only need the HF token for faster downloads.

## Optional vLLM Arguments

Add these to the `args` list in the InferenceService:

| Argument | Description | When to use |
|----------|-------------|-------------|
| `--dtype=float16` | Force FP16 precision | Default is auto; use if model defaults to FP32 |
| `--quantization=awq` | AWQ quantization | Use AWQ-quantized model variants to fit larger models |
| `--gpu-memory-utilization=0.9` | GPU memory fraction | Lower if OOM, raise for throughput |
| `--enforce-eager` | Disable CUDA graphs | Saves ~1GB VRAM, slightly slower |
| `--tensor-parallel-size=1` | Number of GPUs | Always 1 for single L4 |
| `--max-num-seqs=4` | Max concurrent requests | Lower to save memory |

## Adding to deploy.sh (Optional)

To make your model a first-class option in `deploy.sh`, add a case in the model selection:

```bash
# In deploy.sh, add to the case statement:
mymodel)
  ISVC_FILE="$ROOT_DIR/kserve/mymodel-inferenceservice.yaml"
  ISVC_NAME="my-model"
  OPENCLAW_VALUES=("$ROOT_DIR/openclaw/values-mymodel.yaml")
  MODEL_DISPLAY="My Model Name"
  ;;
```

Then use: `./deploy.sh --model mymodel`

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `OutOfMemory` / vLLM crashes | Reduce `--max_model_len` (try 4096 or 2048) |
| Model download stuck | Check HF token; verify model ID is correct |
| "Model not found" in OpenClaw | Ensure `models[].id` matches HuggingFace ID exactly |
| Pod stuck in `Pending` | GPU quota issue — check `kubectl describe pod -n kserve <pod>` |
| vLLM OOM at startup | Model too large for L4; try a smaller model or add `--enforce-eager` |

## Verifying Your Deployment

```bash
# Check InferenceService status
kubectl get inferenceservice -n kserve

# Check model pod logs
kubectl logs -n kserve -l serving.kserve.io/inferenceservice=<isvc-name> -f

# Test the endpoint directly
kubectl exec -n openclaw deploy/openclaw -- \
  curl -s http://<isvc-name>-predictor.kserve.svc.cluster.local/v1/models

# Test a chat completion
kubectl exec -n openclaw deploy/openclaw -- \
  curl -s http://<isvc-name>-predictor.kserve.svc.cluster.local/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"<hf-model-id>","messages":[{"role":"user","content":"Hello"}],"max_tokens":50}'
```
