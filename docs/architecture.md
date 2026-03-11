# OpenClaw + KServe Architecture

## System Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          Google Cloud Platform                              │
│                                                                             │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                    GKE Cluster (us-west4-a)                          │  │
│  │                    Provisioned by Terraform                          │  │
│  │                                                                       │  │
│  │  ┌─────────────────────────────────────────────────────────────────┐  │  │
│  │  │              System Node Pool (e2-standard-2, spot)             │  │  │
│  │  │              1-4 nodes, always running                          │  │  │
│  │  │                                                                 │  │  │
│  │  │  ┌──────────────┐  ┌──────────────┐  ┌───────────────────────┐ │  │  │
│  │  │  │ cert-manager │  │    Istio      │  │   KServe Controller   │ │  │  │
│  │  │  │              │  │  ┌─────────┐  │  │                       │ │  │  │
│  │  │  │ TLS certs    │  │  │ istiod  │  │  │ Watches               │ │  │  │
│  │  │  │ for webhooks │  │  └─────────┘  │  │ InferenceService CRs  │ │  │  │
│  │  │  │              │  │  ┌─────────┐  │  │ Creates Deployments,  │ │  │  │
│  │  │  │              │  │  │ gateway │  │  │ Services, Ingress     │ │  │  │
│  │  │  │              │  │  │ (LB)   │  │  │                       │ │  │  │
│  │  │  └──────────────┘  │  └─────────┘  │  └───────────────────────┘ │  │  │
│  │  │                    └──────────────┘                              │  │  │
│  │  │  ┌──────────────────────────────────────────────────────────┐   │  │  │
│  │  │  │              OpenClaw Pod (ns: openclaw)                  │   │  │  │
│  │  │  │                                                          │   │  │  │
│  │  │  │  ┌────────────────────┐    ┌──────────────────────────┐  │   │  │  │
│  │  │  │  │  Node.js Gateway   │    │  5Gi PVC                 │  │   │  │  │
│  │  │  │  │  Port 18789        │    │  Conversation history    │  │   │  │  │
│  │  │  │  │  WebSocket + HTTP  │    │  Device pairings         │  │   │  │  │
│  │  │  │  └────────┬───────────┘    └──────────────────────────┘  │   │  │  │
│  │  │  │           │                                              │   │  │  │
│  │  │  └───────────┼──────────────────────────────────────────────┘   │  │  │
│  │  └──────────────┼──────────────────────────────────────────────────┘  │  │
│  │                 │ HTTP POST /v1/chat/completions                      │  │
│  │                 │ (in-cluster DNS)                                    │  │
│  │  ┌──────────────▼──────────────────────────────────────────────────┐  │  │
│  │  │              GPU Node Pool (g2-standard-4 + L4, spot)           │  │  │
│  │  │              0-1 nodes, scales to zero when idle                │  │  │
│  │  │                                                                 │  │  │
│  │  │  ┌──────────────────────────────────────────────────────────┐   │  │  │
│  │  │  │         vLLM Model Pod (ns: kserve)                      │   │  │  │
│  │  │  │                                                          │   │  │  │
│  │  │  │  ┌─────────────────┐  ┌──────────────────────────────┐  │   │  │  │
│  │  │  │  │ vLLM Engine     │  │  NVIDIA L4 GPU (24GB VRAM)   │  │   │  │  │
│  │  │  │  │ Port 8080       │  │  Model weights loaded here   │  │   │  │  │
│  │  │  │  │ OpenAI-compat   │  │                              │  │   │  │  │
│  │  │  │  │ API             │  │  Llama 3.2 3B (~6GB FP16)    │  │   │  │  │
│  │  │  │  └─────────────────┘  │  or Qwen 3.5 2B (~4GB FP16) │  │   │  │  │
│  │  │  │                       └──────────────────────────────┘  │   │  │  │
│  │  │  └──────────────────────────────────────────────────────────┘   │  │  │
│  │  └────────────────────────────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
         ▲
         │ kubectl port-forward
         │
    ┌────┴─────┐
    │  Browser  │
    │ :18789    │
    └──────────┘
```

## Request Flow

```
 User (Browser)
      │
      │  WebSocket / HTTP
      │  http://localhost:18789/?token=<TOKEN>
      ▼
 ┌──────────┐     HTTP POST (OpenAI-compatible)      ┌──────────────┐
 │ OpenClaw │ ──────────────────────────────────────► │  vLLM Pod    │
 │ Gateway  │     llama-3-2b-predictor.               │  (KServe)    │
 │          │     kserve.svc.cluster.local:80          │  GPU: L4     │
 │          │ ◄────────────────────────────────────── │  Port: 8080  │
 └──────────┘     JSON response                       └──────────────┘
      │
      ▼
 User sees response
```

## Deployment Flow (deploy.sh)

**Local models (llama/qwen):**

```
 ┌─────────────────────────────────────────────┐
 │  Step 1: Terraform                          │
 │  terraform apply                            │
 │  → GKE cluster + system pool + GPU pool     │
 │                                (~8-12 min)  │
 └──────────────────┬──────────────────────────┘
                    ▼
 ┌─────────────────────────────────────────────┐
 │  Step 2: KServe Stack                       │
 │  install-kserve.sh                          │
 │  → cert-manager → Istio → KServe           │
 │                                 (~3-5 min)  │
 └──────────────────┬──────────────────────────┘
                    ▼
 ┌─────────────────────────────────────────────┐
 │  Step 3: Model Deployment                   │
 │  kubectl apply InferenceService             │
 │  → GPU node scales up → vLLM loads model    │
 │                                (~3-8 min)   │
 └──────────────────┬──────────────────────────┘
                    ▼
 ┌─────────────────────────────────────────────┐
 │  Step 4: OpenClaw                           │
 │  install-openclaw.sh                        │
 │  → Helm install → Pod starts → Ready        │
 │                                (~1-2 min)   │
 └─────────────────────────────────────────────┘

 Total: ~15-25 minutes
```

**OpenAI API mode (no KServe, no GPU):**

```
 ┌─────────────────────────────────────────────┐
 │  Step 1: Terraform                          │
 │  terraform apply                            │
 │  → GKE cluster + system pool               │
 │                                (~8-12 min)  │
 └──────────────────┬──────────────────────────┘
                    │
                    │  Steps 2-3: Skipped
                    │  (KServe, Istio, cert-manager
                    │   not needed for OpenAI API)
                    ▼
 ┌─────────────────────────────────────────────┐
 │  Step 4: OpenClaw                           │
 │  install-openclaw.sh                        │
 │  → Helm install → Pod starts → Ready        │
 │  → Calls OpenAI API directly               │
 │                                (~1-2 min)   │
 └─────────────────────────────────────────────┘

 Total: ~10-15 minutes
```

## Model Selection & Skills

```
 deploy.sh [--model <model>] [--skills]
    │
    ├── --model llama (default)
    │   └── Llama 3.2 3B Instruct
    │       ├── Requires: HF_TOKEN + GPU node
    │       ├── Endpoint: llama-3-2b-predictor.kserve.svc.cluster.local
    │       └── VRAM: ~6GB FP16
    │
    ├── --model qwen
    │   └── Qwen 3.5 2B
    │       ├── Requires: HF_TOKEN + GPU node
    │       ├── Endpoint: qwen-3-5-2b-predictor.kserve.svc.cluster.local
    │       └── VRAM: ~4GB FP16
    │
    ├── --model openai
    │   └── OpenAI API (gpt-4o-mini)
    │       ├── Requires: OPENAI_API_KEY
    │       ├── Endpoint: https://api.openai.com/v1
    │       └── No GPU needed ($0 infrastructure)
    │
    └── --skills (optional, composable with any model)
        └── Adds init-skills init container
            ├── Installs ClawHub skills declaratively
            ├── Applies values-skills.yaml overlay
            └── Skills persist on PVC across restarts
```

## Values File Composition

```
 install-openclaw.sh --values <file> [--values <file> ...]
    │
    │  Helm deep-merges multiple -f files left-to-right.
    │  Model file provides the base config; overlays add features.
    │
    ├── Model files (pick one):
    │   ├── values.yaml          → Llama 3.2 3B
    │   ├── values-qwen.yaml     → Qwen 3.5 2B
    │   └── values-openai.yaml   → OpenAI API
    │
    └── Overlays (optional, stack on top):
        └── values-skills.yaml   → ClawHub skills (init-skills container)
```

## Cost Management (stop.sh / start.sh)

```
 Running (~$10-120/mo)
    │
    ├── stop.sh              → GPU off, system running    (~$7/mo)
    │   └── start.sh         → Redeploy model             (~5-10 min)
    │
    ├── stop.sh --all        → All nodes off               (~$0/mo)
    │   └── start.sh --all   → Scale up + redeploy        (~10-15 min)
    │
    └── stop.sh --destroy    → Delete entire cluster       ($0/mo)
        └── deploy.sh        → Full redeploy              (~25 min)
```

## Kubernetes Namespace Layout

```
 ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐  ┌──────────┐
 │  cert-manager   │  │  istio-system   │  │     kserve      │  │ openclaw │
 │                 │  │                 │  │                 │  │          │
 │  cert-manager   │  │  istiod         │  │  kserve-ctrl    │  │ openclaw │
 │  cainjector     │  │  ingressgateway │  │  vLLM model pod │  │ pod      │
 │  webhook        │  │                 │  │  hf-secret      │  │ PVC      │
 └─────────────────┘  └─────────────────┘  └─────────────────┘  └──────────┘
```
