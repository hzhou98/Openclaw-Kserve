# Troubleshooting & FAQ

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

### "unauthorized: too many failed authentication attempts" after redeployment

This happens because `install-openclaw.sh` generates a **new gateway token** each time it runs (unless you set the `OPENCLAW_GATEWAY_TOKEN` env var). The browser still has the old token cached, and repeated attempts trigger a rate-limit lockout.

**Fix:**

```bash
# 1. Get the new token
kubectl get secret openclaw-env-secret -n openclaw -o jsonpath='{.data.OPENCLAW_GATEWAY_TOKEN}' | base64 -d

# 2. Open the URL with the new token
#    http://localhost:18789/?token=<NEW_TOKEN>
```

**Prevent it on future redeployments** by setting a fixed token:

```bash
export OPENCLAW_GATEWAY_TOKEN=<your-fixed-token>
bash openclaw/install-openclaw.sh --values values-openai.yaml --values values-skills.yaml
```

**If the lockout persists**, restart the pod to reset the rate limiter:

```bash
kubectl rollout restart deployment/openclaw -n openclaw
```

---

[Back to main README](../README.md)
