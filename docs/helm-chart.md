# Helm Chart (Alternative to Scripts)

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

---

[Back to main README](../README.md)
